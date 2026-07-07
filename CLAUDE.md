# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A single Terraform module (`kinesis_log/`) implementing a CloudWatch Logs →
Kinesis Data Stream → Kinesis Firehose → S3 log-archiving pipeline. Deployed
via a manual GitHub Actions workflow, not applied ad hoc as part of any
other build.

## Commands

All Terraform commands run from `kinesis_log/` — it's the only Terraform
root in this repo.

- **Init** (first run, or after backend/provider changes): the backend is
  deliberately account-portable, so `bucket`/`dynamodb_table` are not in
  `main.tf` — supply them at init time:
  `terraform init -backend-config=backend.hcl` (copy `backend.hcl.example`
  first), or explicit `-backend-config="bucket=..." -backend-config="dynamodb_table=..."` flags.
- **Format check**: `terraform fmt -check -diff` (don't auto-fix unless asked — existing minor alignment diffs are known and left as-is).
- **Validate**: `terraform validate`
- **Plan**: `terraform plan` — requires `TF_VAR_s3_bucket_name` env var (see Architecture below for why it's not in tfvars).
- **Apply / Destroy**: `terraform apply` / `terraform destroy` — same env var required. These touch real, billable AWS resources; confirm with the user before running them directly rather than via the CI workflow.

There is no unit test suite. Correctness is checked via `terraform
validate`/`plan`, and end-to-end behavior via the manual test procedure in
`EXPLANATION_AND_USAGE.md` (push a fake log line into a throwaway CloudWatch
log group, confirm a gzip'd file lands in S3 within one buffer interval).

## Architecture

### Module structure
`main.tf` contains everything: S3 destination bucket + lifecycle rule,
Kinesis Data Stream, two IAM roles (CloudWatch→Kinesis, Firehose→Kinesis+S3)
with their own least-privilege inline policies, the CloudWatch Logs
subscription filter that wires a log group into Kinesis, Firehose's own
error-log group, and the Firehose delivery stream itself. Every resource
name derives from `var.name_prefix` (default `cwlogs`) — changing that
default means updating IAM ARNs in `permissions/terraform-deploy-policy.json`
to match. `s3_bucket_name` has no default and is intentionally absent from
`terraform.tfvars` — it must be globally unique and varies per deploy
target, so it's supplied via `TF_VAR_s3_bucket_name` (CI secret or local env
var), never committed.

### Remote state backend is account-portable by design
`main.tf`'s `backend "s3" {}` block only fixes `region`/`key`/`encrypt`;
`bucket` and `dynamodb_table` are deliberately left out and supplied at
`terraform init` time (`backend.hcl` locally, `TF_STATE_BUCKET`/
`TF_STATE_DYNAMODB_TABLE` secrets in CI). This means the same `main.tf`
deploys to any AWS account unmodified — **don't hardcode a bucket name back
into the backend block**; that was a deliberate fix. Earlier, state lived
only on whatever disk happened to run `apply`, so a failed/interrupted run
could orphan real AWS resources with no state for a later `destroy` to find.

### CI (`.github/workflows/kinesis-deploy.yml`)
Manual `workflow_dispatch` only (`action: apply` or `destroy`) — not
triggered on push/PR. Auto-destroys on apply failure
(`if: failure() && action == 'apply'`) to avoid half-applied stacks, but
that only works within the same job run sharing the same local state before
it's written back to the backend; it doesn't help if the backend itself
was unreachable. `simple.yml` in the same directory is an unused leftover
default Actions template, not part of the real deploy path.

### Two separate IAM concerns — don't conflate them
1. The service roles this module *creates* (`cwl_to_kinesis_role`,
   `firehose_role`) — least-privilege, scoped to exactly this stream/bucket,
   defined entirely in `main.tf`.
2. The identity *running* Terraform (a local IAM user, or the CI
   credentials) — needs its own, much broader permissions (create
   buckets/streams/roles/log groups, plus state backend read/write). That
   policy is not expressed in Terraform at all — it's
   `permissions/terraform-deploy-policy.json`, a fill-in-the-placeholders
   IAM policy document attached out-of-band by whoever administers the
   target AWS account (see `permissions/README.md`).

### Docs map
- `README.md` — architecture rationale, usage, cost/tuning notes, full
  remote-state-backend setup instructions.
- `end-to-end.md` — the operational runbook: why/how this exists, manual
  vs. Terraform-created resources (with exact commands for the manual ones),
  running the pipeline, the dummy-log test procedure (Command Prompt),
  checking S3, troubleshooting, and full destroy/teardown including what
  `terraform destroy` does *not* clean up. Start here for actually operating
  this pipeline end to end.
- `EXPLANATION_AND_USAGE.md` — line-by-line `main.tf` walkthrough (the
  bash/Linux version of the test script now lives here; `end-to-end.md` has
  the Windows/cmd version).
- `demo.md` — client-facing status/handoff doc: what's been verified, and
  what still needs pointing at the client's own AWS account before a live
  demo there.
- `permissions/README.md` — how to fill in and attach the IAM policy.

## Gotchas learned the hard way

- **`SubscriptionRequiredException` on Kinesis/Firehose calls is not an IAM
  error.** It means the AWS account itself hasn't activated that service
  (seen on a personal Free Tier account) — no IAM policy fixes it; the
  account owner needs to visit the Kinesis/Firehose console once (or open
  an AWS Support case). Confirmed by contrast: a genuinely missing
  permission on the same account returned the normal `UnauthorizedOperation`/
  `AccessDenied` instead.
- **Git Bash on Windows mangles leading-slash arguments** (MSYS path
  conversion) — e.g. `aws logs describe-log-groups --log-group-name-prefix
  "/aws/..."` silently gets rewritten into a Windows path and fails with a
  confusing `InvalidParameterException`. Set `MSYS_NO_PATHCONV=1` before AWS
  CLI calls involving CloudWatch Logs group names (or anything else starting
  with `/`), or just use Command Prompt/PowerShell instead.
- **CI `terraform init` fails with `Error: Invalid Value ... cannot be empty
  or all whitespace`** when `TF_STATE_BUCKET`/`TF_STATE_DYNAMODB_TABLE`
  GitHub secrets are unset — the `-backend-config="bucket=${{ secrets.X }}"`
  interpolation resolves to an empty string. Happened for real switching to
  a second test account: the secrets simply hadn't been created yet for
  that repo.
- **`terraform destroy` fails with `BucketNotEmpty`** if the destination S3
  bucket still has log objects in it — `aws_s3_bucket.log_destination` has
  `force_destroy = false`. Empty the bucket first (`aws s3 rm s3://<bucket>
  --recursive`), then destroy. See `end-to-end.md` section 8 for the full
  destroy order (state backend and the source log group are never touched
  by `terraform destroy` — they must be cleaned up manually, and only after
  destroy succeeds).
