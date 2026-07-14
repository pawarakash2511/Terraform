# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Three independent Terraform examples, each its own Terraform root:
- `kinesis_log/` — a CloudWatch Logs → Kinesis Data Stream → Kinesis
  Firehose → S3 log-archiving pipeline, deliberately written as one big
  `main.tf`.
- `Terra_example/` — a small EC2 VM example (security group with explicit
  inbound/outbound rules, a Terraform-generated SSH key pair, data sources
  reading existing AWS state), deliberately split across the standard
  multi-file layout (`data.tf`, `variables.tf`, `outputs.tf`, `backend.tf`,
  `providers.tf`, `main.tf`) as a contrast to `kinesis_log`'s style.
- `terraform-cloudtrail-demo/` — a CloudTrail → CloudWatch Logs → Metric
  Filters → Alarms → SNS security-event alerting pipeline (S3 bucket
  deletion and root-account console login detection), split by AWS service
  area (`s3.tf`, `iam.tf`, `cloudtrail.tf`, `cloudwatch.tf`, `sns.tf`, plus
  `versions.tf`/`provider.tf`/`variables.tf`/`locals.tf`/`outputs.tf`/
  `backend.tf`, with `main.tf` kept as a file-map comment only).

All three deploy via manual GitHub Actions workflows, not applied ad hoc as
part of any other build, and share one remote state backend (same S3
bucket/DynamoDB table, different state `key` per root).

## Commands

Each example is its own Terraform root — `cd` into `kinesis_log/`,
`Terra_example/`, or `terraform-cloudtrail-demo/` before running any of
these.

- **Init** (first run, or after backend/provider changes): the backend is
  deliberately account-portable, so `bucket`/`dynamodb_table` are not
  committed — supply them at init time:
  `terraform init -backend-config=backend.hcl` (copy `backend.hcl.example`
  first), or explicit `-backend-config="bucket=..." -backend-config="dynamodb_table=..."` flags.
  All three roots use the *same* bucket/table values — only the state `key`
  differs (`kinesis_log/terraform.tfstate` vs.
  `terra_example/terraform.tfstate` vs. `sec-monitoring/terraform.tfstate`).
- **Format check**: `terraform fmt -check -diff` (don't auto-fix unless asked — existing minor alignment diffs are known and left as-is).
- **Validate**: `terraform validate`
- **Plan**: `terraform plan` — `kinesis_log` requires `TF_VAR_s3_bucket_name` env var (see Architecture below for why it's not in tfvars); `Terra_example` needs no extra env vars; `terraform-cloudtrail-demo` requires `TF_VAR_alarm_notification_emails` (a `list(string)`, validated non-empty) or a `terraform.tfvars` with that key set.
- **Apply / Destroy**: `terraform apply` / `terraform destroy`. These touch real, billable AWS resources; confirm with the user before running them directly rather than via the CI workflow.

There is no unit test suite. Correctness is checked via `terraform
validate`/`plan`, and end-to-end behavior via manual test procedures:
`kinesis_log`'s in `Kinesis_doc/EXPLANATION_AND_USAGE.md`/`Kinesis_doc/end-to-end.md`
(push a fake log line into a throwaway CloudWatch log group, confirm a
gzip'd file lands in S3 within one buffer interval); `Terra_example`'s in
`Terra_example_doc/README.md` (apply, then SSH into the instance using the
Terraform-generated key); `terraform-cloudtrail-demo`'s in
`terraform-cloudtrail-demo-docs/END_TO_END.md` (trigger a real S3
`DeleteBucket` event or a root console login, confirm the CloudWatch alarm
fires and an email arrives).

## Architecture

### `kinesis_log/` module structure
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

### `Terra_example/` — the second example
Six files, one responsibility each: `backend.tf` (terraform block +
required providers `aws`/`tls` + the `backend "s3" {}` block, state key
`terra_example/terraform.tfstate`), `providers.tf` (aws provider config),
`data.tf` (reads the default VPC, its subnets, and the latest Amazon Linux
2023 AMI — the "use existing AWS state" example), `variables.tf`, `main.tf`
(security group with explicit ingress *and* egress rules, a
`tls_private_key`/`aws_key_pair` pair generated by Terraform so there's no
manual key setup, the `aws_instance` itself), `outputs.tf` (last file —
instance ID/IP, security group ID, the sensitive private key, and a
ready-to-use SSH command string). CI is
`.github/workflows/terra-example-deploy.yml`, same shape as
`kinesis-deploy.yml` (manual `workflow_dispatch`, auto-destroy on apply
failure) — no per-run unique name needed here, so it needs no extra secrets
beyond the four already set up for `kinesis_log`.
`permissions/terraform-deploy-policy.json` does not yet cover this root's
EC2/VPC actions — fine while the deploying identity is an AWS admin, but
would need new statements added for a narrower identity.

### `terraform-cloudtrail-demo/` — the third example
Split by AWS service area rather than by file-per-responsibility like
`Terra_example/`: `s3.tf` (CloudTrail's destination bucket — versioned,
encrypted, public-access-blocked, lifecycle-ruled), `iam.tf` (the role
CloudTrail assumes to write into CloudWatch Logs — separate from the S3
bucket policy, which is a distinct authorization path), `cloudtrail.tf` (the
trail itself + its CloudWatch Log Group, multi-region and global-service-events
on, both required for the root-login scenario to be detected), `cloudwatch.tf`
(two metric filter + alarm pairs — S3 `DeleteBucket` and root `ConsoleLogin`),
`sns.tf` (topic + topic policy + one `aws_sns_topic_subscription` per email
via `for_each`). State key `sec-monitoring/terraform.tfstate`, reusing the
same shared backend bucket/table as the other two roots — no separate
bootstrap. CI is `.github/workflows/cloudtrail-deploy.yml`, same shape as
the other two workflows (manual `workflow_dispatch`, single `action`
apply/destroy input, auto-destroy on apply failure); it needs one extra
secret beyond the four shared ones: `ALARM_NOTIFICATION_EMAILS`. Testing
both scenarios is deliberately a manual, documented step
(`terraform-cloudtrail-demo-docs/END_TO_END.md`), not automated in CI — root
login specifically cannot be triggered by a CI credential at all (requires
an interactive root console sign-in), and automating the S3-bucket test
would mean creating/deleting real infrastructure on every apply run.
`permissions/terraform-deploy-policy.json` does not cover this root's
CloudTrail/CloudWatch/SNS actions — fine while the deploying identity is an
AWS admin, but would need new statements added for a narrower identity.

### Docs map
- `Kinesis_doc/README.md` — architecture rationale, usage, cost/tuning
  notes, full remote-state-backend setup instructions.
- `Kinesis_doc/end-to-end.md` — the operational runbook: why/how this
  exists, manual vs. Terraform-created resources (with exact commands for
  the manual ones), running the pipeline, the dummy-log test procedure
  (Command Prompt), checking S3, troubleshooting, and full destroy/teardown
  including what `terraform destroy` does *not* clean up. Start here for
  actually operating this pipeline end to end.
- `Kinesis_doc/EXPLANATION_AND_USAGE.md` — line-by-line `main.tf` walkthrough
  (the bash/Linux version of the test script lives here;
  `Kinesis_doc/end-to-end.md` has the Windows/cmd version).
- `Kinesis_doc/getting-started.md` — deployment status/checklist doc: what's
  been verified, and what still needs pointing at your own AWS account
  before a live run there.
- `Terra_example_doc/README.md` — the VM example's equivalent: file layout,
  the data-source walkthrough, manual-vs-Terraform breakdown, running it,
  connecting over SSH, and destroy notes.
- `terraform-cloudtrail-demo-docs/README.md` — architecture, folder layout,
  local deployment steps for the CloudTrail/CloudWatch/SNS example.
- `terraform-cloudtrail-demo-docs/GUIDE.md` — concept-by-concept explanation
  of why each resource exists and what AWS does internally at each step.
- `terraform-cloudtrail-demo-docs/EXPLANATION_AND_USAGE.md` — file-by-file
  walkthrough of every `.tf` file in `terraform-cloudtrail-demo/`.
- `terraform-cloudtrail-demo-docs/END_TO_END.md` — the operational runbook:
  required secrets, manual-vs-Terraform breakdown, confirming the SNS
  subscription, triggering both test scenarios (bash + Windows Command
  Prompt/PowerShell for the DeleteBucket one), CLI verification at each
  pipeline stage, troubleshooting, and destroy/teardown.
- `permissions/README.md` — how to fill in and attach the IAM policy
  (currently `kinesis_log`-only, see above).
- Root `README.md` — short index pointing into all three examples' docs.

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
  --recursive`), then destroy. See `Kinesis_doc/end-to-end.md` section 8 for the full
  destroy order (state backend and the source log group are never touched
  by `terraform destroy` — they must be cleaned up manually, and only after
  destroy succeeds).
- **`terraform-cloudtrail-demo`'s SNS email subscription must be manually
  confirmed** (click the link in AWS's "Subscription Confirmation" email)
  or alerts silently never arrive — nothing in Terraform, the CloudWatch
  console, or the alarm state indicates this is the problem; check
  subscription status first (`aws sns list-subscriptions-by-topic`) when
  "the alarm fired but no email showed up."
- **`terraform-cloudtrail-demo`'s root-login scenario cannot be tested from
  CI** — it requires an interactive AWS Console sign-in as the literal root
  user (not an IAM admin), so it's deliberately left out of the automated
  workflow and documented as a manual step only.
