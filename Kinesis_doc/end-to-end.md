# End-to-End Runbook — CloudWatch Logs → Kinesis → Firehose → S3

This is the single operational runbook: why this exists, how it works, what
you must set up by hand vs. what Terraform creates, how to run it, how to
test it with a dummy log line, and how to tear it down safely. Concrete
example values below (account `183533197175`, region `eu-west-2`, bucket
`cwlogs-tfstate-183533197175`) are from the live test run against the second
test account — swap them for whatever account you're actually pointed at.

---

## 1. Why we're doing this

Application logs currently sitting in CloudWatch Logs need to be archived
somewhere durable and queryable, without paying for a full logging
platform. This pipeline streams every log event out of a CloudWatch Log
Group and lands it, gzip'd and partitioned by date, in S3 — cheaply, in
near-real-time, with automatic expiry so storage doesn't grow forever.

## 2. How we're doing this

```
CloudWatch Log Group
   │  (subscription filter, near-real-time)
   ▼
Kinesis Data Stream          <- replayable buffer, 24h retention
   │
   ▼
Kinesis Firehose             <- batches records, writes to S3
   │
   ▼
S3 Bucket (gzip'd, partitioned by date, auto-expires after N days)
```

- **Kinesis Data Stream** in the middle (rather than wiring CloudWatch Logs
  straight to Firehose) so the raw stream can have other consumers later
  (e.g. a Lambda alerting on `ERROR` lines) without touching the logging
  side again.
- **Firehose** is the only AWS piece that natively knows how to batch
  records and write files to S3 — a raw Kinesis stream can't do that itself.
- Everything is defined in one Terraform module (`kinesis_log/main.tf`) and
  deployed via a manual GitHub Actions workflow
  (`.github/workflows/kinesis-deploy.yml`), not run ad hoc from a laptop —
  see `CLAUDE.md` for the full dev reference.

For a block-by-block walkthrough of every resource in `main.tf`, see
`EXPLANATION_AND_USAGE.md`.

## 3. What must exist before you can run this — manual vs. Terraform

### Created manually, once per AWS account (Terraform never touches these)

**a) The Terraform state backend** (S3 bucket + DynamoDB lock table) — has
to exist *before* `terraform init` can even run, since it's where Terraform
itself stores state:
```bash
aws s3api create-bucket --bucket cwlogs-tfstate-183533197175 \
  --region eu-west-2 --create-bucket-configuration LocationConstraint=eu-west-2
aws s3api put-bucket-versioning --bucket cwlogs-tfstate-183533197175 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket cwlogs-tfstate-183533197175 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket cwlogs-tfstate-183533197175 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name cwlogs-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region eu-west-2
```
Why manual: this is infrastructure *for* Terraform, so Terraform can't
create it (chicken-and-egg). Why it exists at all: without a remote backend,
state lives only on whatever machine ran `apply`; a failed/interrupted run
then leaves real AWS resources behind that no later `destroy` can find.

**b) The source CloudWatch Log Group** — the log group the pipeline
subscribes to:
```bash
aws logs create-log-group --log-group-name /test/kinesis-pipeline --region eu-west-2
```
Why manual: `main.tf` deliberately does not create this. In a real
deployment, whatever app/service is already logging (ECS, Lambda, EC2)
owns and creates its own log group — Terraform just subscribes to it. For
testing without a real app, you create a throwaway one, as above.

**c) The IAM identity that runs Terraform** — an IAM user (e.g. `Akash_AWS1`)
with either admin rights (as used on this test account) or the narrower
policy in `permissions/terraform-deploy-policy.json` attached (fill in the
account ID, region, and bucket/table names, then follow
`permissions/README.md`). This is a completely separate concern from the
service roles Terraform creates in step 4 below — see `CLAUDE.md`'s "Two
separate IAM concerns" section.

### Created manually, once per repo: GitHub Actions secrets

Where: GitHub repo → **Settings → Secrets and variables → Actions → New
repository secret**.

| Secret | What to put |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key for the IAM identity from 3c |
| `AWS_SECRET_ACCESS_KEY` | Its secret key |
| `TF_STATE_BUCKET` | The state bucket from 3a, e.g. `cwlogs-tfstate-183533197175` |
| `TF_STATE_DYNAMODB_TABLE` | The lock table from 3a, e.g. `cwlogs-tf-lock` |
| `KINESIS_S3_BUCKET_NAME` | A **new, globally-unique** name for the destination bucket Terraform will create (step 4) — not the state bucket |

If any of these is blank, `terraform init` fails with `Error: Invalid Value
... The value cannot be empty or all whitespace` — this happened on this
project's first CI run after switching accounts, because the secrets simply
hadn't been created yet.

### Created BY Terraform (11 resources, `kinesis_log/main.tf`)

| Resource | Why |
|---|---|
| `aws_s3_bucket.log_destination` + lifecycle rule | Final archive; lifecycle auto-expires objects after `log_retention_days` so storage doesn't grow forever |
| `aws_kinesis_stream.log_stream` | The replayable streaming buffer between CloudWatch and Firehose |
| `aws_iam_role.cwl_to_kinesis_role` + policy | Lets CloudWatch Logs push into *this* stream only — least privilege |
| `aws_cloudwatch_log_subscription_filter.to_kinesis` | The actual wiring: log group → Kinesis stream |
| `aws_iam_role.firehose_role` + policy | Lets Firehose read *this* stream and write to *this* bucket only |
| `aws_cloudwatch_log_group.firehose_error_logs` + stream | Firehose's own error log, so failed deliveries are visible instead of silently dropped |
| `aws_kinesis_firehose_delivery_stream.to_s3` | The consumer that batches Kinesis records and writes gzip'd files to S3 |

Why Terraform owns these and not the items above: these are all
purpose-built for this pipeline and safe to fully manage/destroy as a unit;
the items above (state backend, source log group, IAM user) either need to
exist *before* Terraform runs, or are shared/owned by something else.

## 4. Running the pipeline

Trigger `.github/workflows/kinesis-deploy.yml` via GitHub Actions →
**Run workflow** (`workflow_dispatch`) → `action: apply`. Under the hood it:
1. Checks out the repo, installs Terraform 1.6.6
2. Configures AWS credentials from the secrets above
3. `terraform init -backend-config="bucket=..." -backend-config="dynamodb_table=..."`
4. `terraform plan` then `terraform apply -auto-approve`, with
   `TF_VAR_s3_bucket_name` from `KINESIS_S3_BUCKET_NAME`

If `apply` fails partway, the workflow auto-runs `terraform destroy` in the
same job (`if: failure() && action == 'apply'`) so nothing is left half
-created — this only works because state is remote (step 3a), so the
destroy step can see exactly what the failed run already created.

## 5. Testing with a dummy log line

Once `apply` succeeds, from Command Prompt:

```
aws logs create-log-stream --log-group-name /test/kinesis-pipeline --log-stream-name test-stream-1 --region eu-west-2

for /f %i in ('powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()"') do set TS=%i
aws logs put-log-events --log-group-name /test/kinesis-pipeline --log-stream-name test-stream-1 --log-events timestamp=%TS%,message="hello from terraform test 1" --region eu-west-2
```
Repeat the last two lines (new message text) to simulate more log lines.

## 6. Checking S3

Wait ~60-90 seconds (matches this repo's shortened test buffer —
`firehose_buffer_size_mb=1`, `firehose_buffer_interval_seconds=60` in
`terraform.tfvars`), then:
```
aws s3 ls s3://<your-bucket-name>/raw/ --recursive --region eu-west-2
aws s3 cp s3://<your-bucket-name>/raw/year=2026/month=07/day=07/<filename>.gz . --region eu-west-2
powershell -NoProfile -Command "$in=[IO.File]::OpenRead('<filename>.gz'); $out=[IO.File]::Create('<filename>'); $gz=New-Object IO.Compression.GzipStream($in,[IO.Compression.CompressionMode]::Decompress); $gz.CopyTo($out); $gz.Dispose(); $out.Dispose(); $in.Dispose()"
type <filename>
```
You should see your test message wrapped in CloudWatch's subscription
-filter JSON envelope (`logGroup`, `logStream`, `logEvents`, etc.) — that's
the expected format.

## 7. How it's all working together, and troubleshooting

End to end: a `put-log-events` call lands a record in the log group →
the subscription filter (step 3, wired via IAM role `cwl_to_kinesis_role`)
forwards it into the Kinesis stream within seconds → Firehose polls the
stream (via `firehose_role`), buffers records up to 1MB or 60s, then writes
one gzip'd object into `raw/year=.../month=.../day=.../` in S3.

If nothing shows up in S3, check in this order:
1. **Firehose's own error log** — `/aws/kinesisfirehose/cwlogs-to-s3` — shows
   exactly why a delivery failed (e.g. S3 access denied), if it did.
2. **Subscription filter is actually attached**:
   `aws logs describe-subscription-filters --log-group-name /test/kinesis-pipeline --region eu-west-2`
3. **Data is reaching Kinesis at all** — check the `IncomingRecords` metric
   on `cwlogs-log-stream`, or read directly with `get-shard-iterator` +
   `get-records`.

Issues actually hit and fixed on this project (all documented in
`CLAUDE.md`'s "Gotchas" section too):
- `SubscriptionRequiredException` on any Kinesis/Firehose call → the AWS
  account itself hasn't activated that service (seen on a Free Tier
  account) — not an IAM problem.
- `Error: Invalid Value ... cannot be empty` on `terraform init` in CI → a
  required GitHub secret (`TF_STATE_BUCKET`/`TF_STATE_DYNAMODB_TABLE`) was
  blank.
- `ResourceNotFoundException: The specified log group does not exist` on
  `apply` → the source log group (step 3b) wasn't created yet in this
  account before running the pipeline.
- Git Bash on Windows mangles leading-slash AWS CLI arguments — set
  `MSYS_NO_PATHCONV=1` first, or use Command Prompt/PowerShell instead.

## 8. Destroying

Trigger `kinesis-deploy.yml` → `action: destroy`. This runs
`terraform destroy -auto-approve`, which removes **only the 11 resources
Terraform created** (section 3's second table): both S3 lifecycle +
destination bucket, the Kinesis stream, both IAM roles/policies, the
subscription filter, Firehose's error log group/stream, and the Firehose
delivery stream itself.

**Known gotcha**: `aws_s3_bucket.log_destination` has `force_destroy = false`
(the default) — if it still has log objects in it (e.g. from testing),
`terraform destroy` fails with `BucketNotEmpty`. Empty it first:
```
aws s3 rm s3://<your-bucket-name> --recursive --region eu-west-2
```
then re-run destroy.

**What `terraform destroy` does NOT touch** — these were created manually
(section 3) and must be cleaned up by hand if you're fully decommissioning
this AWS account/test setup:

1. **State backend** (delete only after `terraform destroy` has succeeded —
   deleting this first would orphan any resources Terraform hadn't
   destroyed yet, since it'd lose track of them):
   ```
   aws s3 rm s3://cwlogs-tfstate-183533197175 --recursive --region eu-west-2
   aws s3api delete-bucket --bucket cwlogs-tfstate-183533197175 --region eu-west-2
   aws dynamodb delete-table --table-name cwlogs-tf-lock --region eu-west-2
   ```
2. **Source log group**:
   ```
   aws logs delete-log-group --log-group-name /test/kinesis-pipeline --region eu-west-2
   ```
3. **GitHub Actions secrets** (optional — only if the repo/account pairing
   is being retired): remove via repo Settings, or `gh secret remove NAME`.
4. **The IAM user/credentials themselves**, if they were created solely for
   this test and won't be reused.

If you're just tearing down a test run to re-apply later against the *same*
account, skip 1–4 entirely — leave the backend, log group, and secrets in
place and just re-run `action: apply`.
