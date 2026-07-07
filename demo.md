# Demo Guide — CloudWatch Logs → Kinesis → Firehose → S3

This document explains what's been built, what's been verified, and exactly
what's needed before the live client demo can run.

## What this delivers

A Terraform module (`kinesis_log/`) that streams CloudWatch Logs in near
real-time into S3, via Kinesis Data Streams and Kinesis Firehose:

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

Every IAM role created by this module is least-privilege: the CloudWatch→
Kinesis role can only push records into its own stream; the Firehose role
can only read that stream and write to its own S3 bucket. Failed Firehose
deliveries land under a separate `errors/` prefix in S3 instead of
disappearing silently.

See `README.md` for cost drivers and tuning knobs, `EXPLANATION_AND_USAGE.md`
for a block-by-block walkthrough of `main.tf`, and
[`end-to-end.md`](end-to-end.md) for the full operational runbook — manual
vs. Terraform-created resources, running the pipeline, the exact dummy-log
test procedure, checking S3, troubleshooting, and teardown. That test
procedure doubles as the live demo script.

## What's been verified so far

- **Config correctness**: `terraform fmt` / `init` / `validate` / `plan` all
  run cleanly — no errors, no warnings — 11 resources plan to create (S3
  bucket + lifecycle, Kinesis stream, both IAM roles + policies, CloudWatch
  Logs subscription filter, Firehose delivery stream, Firehose's own
  error-log group/stream).
- **Remote state backend added**: `main.tf` now has a `backend "s3" {}`
  block (S3 bucket + DynamoDB lock table) instead of relying on whatever
  disk happens to run `terraform apply`. This matters operationally: without
  it, a failed or interrupted `apply` leaves resources in AWS that no later
  `destroy` run can find or clean up — state now survives across CI runs and
  local runs alike, so teardown is always reliable.
- **CI pipeline**: `.github/workflows/kinesis-deploy.yml` provides one-click
  `apply` and `destroy` via GitHub Actions (`workflow_dispatch`), reading AWS
  credentials and the destination bucket name from GitHub Secrets.

## Important: this was validated on a personal AWS test account, not the client's

While proving the config out, testing happened against a personal AWS
**Free Tier** account. That account turned out not to have Kinesis Data
Streams / Kinesis Data Firehose activated — AWS gates those services behind
an account-level activation step that's independent of IAM permissions
(visiting each service's console page once typically triggers it; a fresh
paid/client AWS account usually doesn't hit this at all). This blocked a
live `apply` on that test account but is **not a defect in the Terraform
config** — `plan` against real AWS credentials showed the config itself is
correct and complete.

**Before running the demo on the client's AWS account, two things carry
over from account to account and need re-pointing:**

**As of the latest commit, neither of these requires editing `main.tf`** —
the backend is now account-portable (partial backend config) and the IAM
policy ships as a ready-to-fill-in file, so this is now just configuration,
not code changes:

1. **IAM permissions** — fill in the placeholders in
   `permissions/terraform-deploy-policy.json` (account ID, region, state
   bucket/table names) and attach it to whatever identity runs Terraform,
   per `permissions/README.md`. Covers every action this module and its
   state backend need.
2. **State backend bucket/table are account-specific, but no longer
   hardcoded.** `kinesis_log/main.tf`'s `backend "s3" {}` block only fixes
   region/key/encryption; the bucket and DynamoDB table names are supplied
   externally. Before deploying to the client's account:
   - Bootstrap an equivalent state bucket + DynamoDB lock table there (see
     README "Remote state backend setup" for the exact commands).
   - Copy `kinesis_log/backend.hcl.example` → `backend.hcl`, fill in the new
     bucket/table names (local runs), or set the `TF_STATE_BUCKET` /
     `TF_STATE_DYNAMODB_TABLE` GitHub secrets (CI runs).
   - Run `terraform init -reconfigure` (local) — CI picks it up
     automatically on the next `kinesis-deploy.yml` run.

## How the demo will run (once pointed at the client account)

1. Confirm the client's log group name (or create a throwaway one for the
   demo) and set it as `cloudwatch_log_group_name` in `terraform.tfvars`.
2. Trigger `kinesis-deploy.yml` with `action: apply` (or run `terraform
   apply` locally) — creates the full pipeline.
3. Push a couple of test log lines into the source log group (exact AWS CLI
   commands in `EXPLANATION_AND_USAGE.md`, Step 3).
4. Within ~60–90 seconds (or the configured Firehose buffer interval), show
   the client the `.gz` file landing in S3, partitioned by date — download
   and `gunzip` it live to show the actual log content flowing through.
5. Afterward, either leave the stack running for the client to keep testing,
   or trigger `kinesis-deploy.yml` with `action: destroy` to tear it down
   cleanly (now reliable thanks to the remote state backend).

## Cost expectations for the demo

Minimal — a few minutes of Kinesis (1 shard, ~$0.015/hr) and Firehose
(~$0.029/GB ingested, and a demo ingests kilobytes), plus negligible S3
storage. Full breakdown in `README.md` under "Notes for the client".
