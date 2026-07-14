# Terraform File-by-File Explanation — CloudTrail Security Monitoring

This is the line-by-line/file-by-file companion to `README.md` (architecture)
and `GUIDE.md` (conceptual "why"). Read this when you want to know exactly
what each `.tf` file in `terraform-cloudtrail-demo/` declares and why it's
written the way it is.

---

## `versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
```
Pins Terraform core and the AWS provider major version. Without this, a
teammate running a newer CLI/provider could see subtly different default
behavior (new default arguments, renamed attributes) — a common source of
hard-to-debug drift between machines.

---

## `provider.tf`

```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```
Configures the AWS provider. `default_tags` applies automatically to every
taggable resource this provider creates, so cost-allocation/ownership tags
don't need repeating on each resource individually. The two `data` sources
read the deploying account's ID and the active region at plan/apply time —
used throughout the project (via `locals.tf`) to build ARNs and unique
names without hardcoding an account ID anywhere.

---

## `backend.tf`

```hcl
terraform {
  backend "s3" {
    key     = "sec-monitoring/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
```
`bucket`/`dynamodb_table` are deliberately absent — supplied at `terraform
init` time via `-backend-config` (locally from `backend.hcl`, in CI from the
`TF_STATE_BUCKET`/`TF_STATE_DYNAMODB_TABLE` secrets). This is the *same*
shared backend bucket/table as `kinesis_log/` and `Terra_example/` — only
the `key` differs, keeping this root's state file separate within the same
bucket. The bucket/table must already exist before the first `init` here;
they were created once, for the other two examples, and this root reuses
them rather than bootstrapping its own.

---

## `variables.tf`

Every configurable input, so the project is reusable across
accounts/environments without touching resource code:
- `project_name` (default `sec-monitoring`), `environment` (default `dev`) —
  combined in `locals.tf` into the naming prefix for every resource.
- `aws_region` (default `eu-west-2`) — the trail's home region for regional
  resources (log group, alarms, SNS); CloudTrail itself is still
  multi-region regardless of this setting.
- `log_retention_days` (default 90) — CloudWatch Logs retention; AWS only
  accepts specific values (1, 3, 5, 7, 14, 30, 60, 90, ...).
- `s3_log_retention_days` (default 365) — how long raw CloudTrail log files
  live in S3 before lifecycle expiration.
- `alarm_notification_emails` (`list(string)`, no default, **validated
  non-empty**) — the one required input; must be supplied via
  `terraform.tfvars` locally or `TF_VAR_alarm_notification_emails` in CI.
  The validation block exists so a forgotten value fails fast at plan time
  instead of silently deploying an alerting pipeline nobody is subscribed to.
- `metric_alarm_period_seconds` / `metric_alarm_evaluation_periods` /
  `metric_alarm_threshold` — alarm tuning knobs, defaulted to
  60s/1/1 (fire on the very first breaching period — appropriate for
  security events, unlike a CPU alarm where you'd want a sustained trend).

---

## `locals.tf`

```hcl
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  common_tags = { Project = var.project_name, Environment = var.environment, ManagedBy = "Terraform" }
}
```
Computed values used in more than one file. `name_prefix` (e.g.
`sec-monitoring-dev`) is what every resource name in this project derives
from — change `project_name` or `environment` and every resource renames
consistently. `account_id`/`region` avoid repeating the same `data.*`
interpolation across `s3.tf`, `iam.tf`, `sns.tf`.

---

## `s3.tf`

Creates `aws_s3_bucket.cloudtrail` (named
`${name_prefix}-cloudtrail-logs-${account_id}` — the account ID suffix
keeps the globally-unique S3 name collision-free across accounts), plus:
- `aws_s3_bucket_public_access_block` — blocks all public access (CIS 2.1.5;
  CloudTrail logs contain IAM identities and source IPs).
- `aws_s3_bucket_versioning` — protects against accidental/malicious
  overwrite or delete of log objects.
- `aws_s3_bucket_server_side_encryption_configuration` — SSE-S3 (AES256) on
  every object by default, without relying on the writer to specify it.
- `aws_s3_bucket_lifecycle_configuration` — transitions to STANDARD_IA at 90
  days, GLACIER at 180, expires at `var.s3_log_retention_days`.
- `data.aws_iam_policy_document.cloudtrail_bucket_policy` +
  `aws_s3_bucket_policy.cloudtrail` — a **resource-based** policy (distinct
  from the IAM role in `iam.tf`) authorizing only the CloudTrail service
  principal, only for *this* trail's ARN (`aws:SourceArn` condition), to
  `GetBucketAcl` and `PutObject` under `AWSLogs/<account-id>/*` with the
  `bucket-owner-full-control` ACL condition.

---

## `iam.tf`

CloudTrail's S3 write access comes from the bucket policy above; its
CloudWatch Logs write access requires a completely separate mechanism —
CloudTrail must **assume an IAM role** that grants `logs:PutLogEvents`.
Forgetting this is the single most common misconfiguration in real
deployments: S3 delivery keeps working fine while CloudWatch Logs stays
silently empty, and nothing tells you that's happening.
- `data.aws_iam_policy_document.cloudtrail_assume_role` — trust policy
  scoped to only the `cloudtrail.amazonaws.com` service principal.
- `aws_iam_role.cloudtrail_cloudwatch_role` — the role itself.
- `data.aws_iam_policy_document.cloudtrail_cloudwatch_permissions` +
  `aws_iam_policy.cloudtrail_cloudwatch_policy` — least-privilege, scoped to
  exactly `${cloudtrail log group arn}:*` (the trailing `:*` covers every
  log stream CloudTrail creates within that one group).
- `aws_iam_role_policy_attachment` — an explicit attachment resource (rather
  than an inline policy) so the policy is independently visible/manageable
  in the IAM console.

---

## `cloudtrail.tf`

- `aws_cloudwatch_log_group.cloudtrail` — the log group CloudTrail streams
  into (`/aws/cloudtrail/${name_prefix}`), read by the metric filters in
  `cloudwatch.tf`.
- `aws_cloudtrail.main` — the trail itself:
  - `is_multi_region_trail = true` — captures every region, not just
    `eu-west-2`; without this, an attacker (or misconfigured automation) in
    an unmonitored region goes completely undetected (CIS 3.1).
  - `include_global_service_events = true` — captures IAM/STS/global events;
    **required** for the root-login scenario, since console sign-in is a
    global service event.
  - `enable_log_file_validation = true` — SHA-256 digest files so log
    tampering/deletion can be cryptographically detected after delivery.
  - `cloud_watch_logs_group_arn` / `cloud_watch_logs_role_arn` — the two
    lines that actually wire this trail into the CloudWatch Log Group above,
    using the IAM role from `iam.tf`. Without these two lines, CloudTrail
    would only write to S3 and none of this project's alerting would work.
  - `depends_on` — explicit dependency on the S3 bucket policy and IAM role
    attachment; CloudTrail validates it's authorized to write to both
    destinations *at creation time*, so both must exist first or trail
    creation fails.

---

## `cloudwatch.tf`

Two independent metric-filter + alarm pairs:

**Scenario 1 — `delete_bucket`**: pattern
`{ ($.eventSource = "s3.amazonaws.com") && ($.eventName = "DeleteBucket") }`
— narrowed to the S3 service specifically, avoiding collision with any other
service's similarly-named action. Feeds
`SecurityMonitoring/DeleteBucketEventCount`.

**Scenario 2 — `root_login`**: pattern
`{ ($.eventName = "ConsoleLogin") && ($.userIdentity.type = "Root") }` — the
second condition is what makes this root-only; without it, every IAM user's
console login would also match. Feeds `SecurityMonitoring/RootLoginEventCount`.

Both alarms share the same shape: `comparison_operator =
GreaterThanOrEqualToThreshold`, `threshold = var.metric_alarm_threshold`
(default 1 — any single occurrence alerts), `period`/`evaluation_periods`
from variables (default 60s/1 — fire on the first breaching period, no
trend-waiting), `treat_missing_data = "notBreaching"` (absence of matching
events is the healthy state — without this, a quiet period can flip the
alarm to `INSUFFICIENT_DATA`, a common source of noisy false alerts), and
both `alarm_actions`/`ok_actions` point at the SNS topic from `sns.tf`.

---

## `sns.tf`

- `aws_sns_topic.security_alerts` — the fan-out topic both alarms publish to.
- `data.aws_iam_policy_document.sns_topic_policy` +
  `aws_sns_topic_policy` — authorizes the `cloudwatch.amazonaws.com` service
  principal to publish, scoped by the `aws:SourceAccount` condition. Without
  this, alarms show "Failed" delivery attempts with no obvious surfaced
  error — another common silent-failure point.
- `aws_sns_topic_subscription.email` — one subscription **per address** in
  `var.alarm_notification_emails`, using `for_each = toset(...)` rather than
  `count` so adding/removing one email later only touches that specific
  subscription resource, not every subscription's index. Each address
  requires manual confirmation (an AWS anti-abuse measure) before it
  receives anything — see `END_TO_END.md` Section 6.

---

## `outputs.tf`

Surfaces everything needed to verify a deployment or hand it off without
digging through the console: `cloudtrail_arn`, `cloudtrail_s3_bucket_name`,
`cloudwatch_log_group_name`, `sns_topic_arn`, both alarms' names, and
`pending_email_confirmations` (echoes back the input list as a reminder that
each address needs manual confirmation).

---

## `main.tf`

Deliberately near-empty — Terraform loads every `.tf` file in the directory
and merges them into one configuration graph, so there's no required
single entry point. This file exists purely as a navigable index/file-map
comment, since resources here are split by AWS service area rather than
concentrated in one file (contrast with `kinesis_log/main.tf`, which
deliberately puts everything in one file as a different style example).
