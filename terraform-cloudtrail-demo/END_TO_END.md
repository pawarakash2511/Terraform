# End-to-End Guide — CloudTrail Security Monitoring

This is the operational runbook for this project: deploying it, confirming
the SNS subscription, triggering both detection scenarios, verifying each
stage of the pipeline, troubleshooting, and tearing it down. For the
architecture overview and file layout, see `README.md`. For a deep
concept-by-concept walkthrough of why each resource exists, see `GUIDE.md`.

---

## 1. Why this exists

CloudTrail records every API call in the account, but nobody is watching that
record in real time on its own. This project turns two specific, high-value
security events — an S3 bucket deletion and a root-account console login —
into an email alert within roughly 1–3 minutes of the event happening,
by chaining CloudTrail → CloudWatch Logs → Metric Filter → Metric → Alarm →
SNS → email.

## 2. How it works (short version)

1. CloudTrail streams every API call into a CloudWatch Log Group in near
   real time (separately from its ~5-minute batched delivery to S3).
2. A metric filter pattern-matches each incoming log line; on a match it
   increments a CloudWatch metric.
3. An alarm attached to that metric evaluates every 60 seconds and flips to
   `ALARM` once the metric is `>= 1`.
4. The alarm publishes to an SNS topic, which emails every confirmed
   subscriber.

See `GUIDE.md` for the full reasoning behind each step, including the two
most common misconfigurations (CloudWatch Logs delivery silently not wired
up; SNS subscription never confirmed).

---

## 3. Required GitHub Secrets

| Secret | Value | Shared with other examples? |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key with the permissions in README Section 5 | Yes |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key | Yes |
| `TF_STATE_BUCKET` | The shared Terraform state bucket | Yes |
| `TF_STATE_DYNAMODB_TABLE` | The shared state lock table | Yes |
| `ALARM_NOTIFICATION_EMAILS` | Terraform list literal, e.g. `["you@example.com"]` | No — specific to this project |

If you've already run `kinesis_log` or `Terra_example` in this AWS account,
the first four secrets are already set — only `ALARM_NOTIFICATION_EMAILS`
needs adding.

---

## 4. Manual vs. Terraform-created resources

| Resource | Created by |
|---|---|
| State S3 bucket + DynamoDB lock table | Manual, once per AWS account — shared with `kinesis_log`/`Terra_example` |
| GitHub Secrets (table above) | Manual, once |
| SNS email subscription **confirmation** (clicking the link AWS emails you) | Manual, every time the subscribed address changes |
| CloudTrail trail, its CloudWatch Log Group, S3 bucket, metric filters, alarms, SNS topic/subscription, IAM role/policy | Terraform (`terraform apply`) |

---

## 5. Running the pipeline

Trigger `.github/workflows/cloudtrail-deploy.yml` via **GitHub Actions → Run
workflow → action: apply**. This initializes against the shared backend,
plans, applies, and prints `terraform output` (trail ARN, S3 bucket name,
CloudWatch log group name, SNS topic ARN, both alarm names).

---

## 6. Confirm the SNS subscription

Immediately after apply, check the inbox of every address listed in
`alarm_notification_emails`. AWS sends an email titled **"AWS Notification -
Subscription Confirmation"**. Click **Confirm subscription** — until you do,
the subscription status is `PendingConfirmation` and no alerts will be
delivered, with no error shown anywhere in Terraform or the CloudWatch
console.

Verify programmatically:
```bash
aws sns list-subscriptions-by-topic --topic-arn "$(terraform output -raw sns_topic_arn)"
```
Look for `"SubscriptionArn"` — if it literally reads `"PendingConfirmation"`
instead of a real ARN, the email has not yet been confirmed.

---

## 7. Testing Scenario 1 — DeleteBucket

Creates a throwaway S3 bucket, then immediately deletes it — a real
`DeleteBucket` CloudTrail event that should trigger the alarm within 1–3
minutes.

**Bash:**
```bash
BUCKET="tf-test-delete-me-$(date +%s)"
aws s3api create-bucket --bucket "$BUCKET" --region eu-west-2 \
  --create-bucket-configuration LocationConstraint=eu-west-2
aws s3api delete-bucket --bucket "$BUCKET" --region eu-west-2
```

**Windows Command Prompt:**
```cmd
for /f %i in ('powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"') do set BUCKET=tf-test-delete-me-%i
aws s3api create-bucket --bucket %BUCKET% --region eu-west-2 --create-bucket-configuration LocationConstraint=eu-west-2
aws s3api delete-bucket --bucket %BUCKET% --region eu-west-2
```

Wait 1–3 minutes, then check the alarm state (Section 9) and your inbox.

---

## 8. Testing Scenario 2 — Root Login

⚠️ Requires signing in to the AWS Console **as the root user** (the
email/password used to originally create the AWS account) — not an IAM user,
even an administrator one, since the metric filter specifically matches
`userIdentity.type = "Root"`. This cannot be scripted or run from CI.

1. Sign out of any IAM user session.
2. Go to the AWS Sign-In page and choose **Root user**.
3. Sign in with the root email + password.
4. Wait 1–3 minutes, then check the alarm state and your inbox.

If root credentials aren't available (common in shared sandbox accounts),
`GUIDE.md` Section 8 walks through a sample root-login CloudTrail event
instead, so you can still verify the pattern logic without triggering it
live.

---

## 9. Verifying each stage via the CLI

**CloudTrail is logging:**
```bash
aws cloudtrail get-trail-status --name "$(terraform output -raw cloudtrail_arn)"
```
Look for `"IsLogging": true`.

**CloudWatch Logs is receiving events:**
```bash
aws logs tail "$(terraform output -raw cloudwatch_log_group_name)" --since 10m
```
You should see a continuous stream of JSON events.

**Metric filters exist:**
```bash
aws logs describe-metric-filters --log-group-name "$(terraform output -raw cloudwatch_log_group_name)"
```

**Metrics are receiving data points** (after triggering a test event):
```bash
aws cloudwatch get-metric-statistics \
  --namespace SecurityMonitoring \
  --metric-name DeleteBucketEventCount \
  --start-time "$(date -u -d '-15 minutes' +%Y-%m-%dT%H:%M:%S)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --period 60 \
  --statistics Sum
```

**Alarm state:**
```bash
aws cloudwatch describe-alarms --alarm-names "$(terraform output -raw delete_bucket_alarm_name)"
```
Look for `"StateValue": "ALARM"` after a test trigger.

**SNS email delivery:** check the subscribed inbox directly — there is no
CLI-visible delivery receipt for email protocol subscriptions.

---

## 10. Expected timeline

After a successful test trigger, in order:
1. The action (bucket deletion or root login) completes in AWS
2. Within seconds, the event appears in `aws logs tail` output
3. Within 1–2 minutes, the corresponding CloudWatch alarm transitions to `ALARM`
4. Within seconds of that, an email arrives at the subscribed address

---

## 11. Troubleshooting

- **No email ever arrives, alarm never leaves OK:** the SNS subscription was
  never confirmed (Section 6) — check subscription status first, before
  anything else.
- **Testing in the wrong region:** the trail is multi-region, but the
  CloudWatch Log Group, metric filters, and alarms are regional
  (`eu-west-2`). If you generate the test event from a different region,
  CloudTrail still records it (multi-region), but confirm you're checking
  the log group/alarm in `eu-west-2`, not wherever the CLI's default region
  happens to be set.
- **Alarm still shows OK right after the test:** CloudWatch Logs delivery
  from CloudTrail is fast (seconds) but not instant, and alarms only
  re-evaluate on their period (60s here) — wait the full 1–3 minutes before
  concluding something's wrong.
- **Root login scenario can't be tested:** requires actual root credentials;
  if unavailable, walk through `GUIDE.md` Section 4's pattern-logic
  explanation with a sample event instead of triggering it live.

---

## 12. Destroy / Teardown

Trigger the workflow with `action: destroy`, or locally:
```bash
aws s3 rm "s3://$(terraform output -raw cloudtrail_s3_bucket_name)" --recursive
terraform destroy -var-file="terraform.tfvars"
```
The S3 bucket must be emptied first — Terraform will not force-delete a
non-empty bucket (`force_destroy` is not set), the same gotcha as
`kinesis_log`'s destination bucket.

**What `terraform destroy` does NOT clean up:**
- The shared state backend (S3 bucket + DynamoDB table) — it's shared with
  `kinesis_log`/`Terra_example`; never delete it until all three roots have
  been destroyed.
- The GitHub Secrets — remove `ALARM_NOTIFICATION_EMAILS` manually if no
  longer needed; the other four secrets are used by the other examples too.
- The SNS subscription confirmation record on AWS's side (harmless — a new
  `apply` later will just require re-confirming).
