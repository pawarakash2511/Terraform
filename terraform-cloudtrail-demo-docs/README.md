# AWS Security Monitoring — CloudTrail + CloudWatch + SNS

Terraform project implementing real-time AWS security event detection and
email alerting, covering two concrete scenarios:

1. **S3 Bucket Deletion** (`DeleteBucket` API call)
2. **Root Account Console Login**

For the full "why does each piece exist" walkthrough, see `GUIDE.md`. For a
file-by-file explanation of every `.tf` file, see `EXPLANATION_AND_USAGE.md`.
For running this end to end (deploying, testing both scenarios, verifying,
tearing down), see `END_TO_END.md`. This file covers architecture, layout,
and a quick local run.

The Terraform code itself lives one level up, in `../terraform-cloudtrail-demo/`
— this doc folder mirrors `Kinesis_doc/` and `Terra_example_doc/`, one doc
folder per example root.

---

## 1. Project Overview

CloudTrail records every API call made in an AWS account. On its own, that's
just a historical record — nobody is watching it in real time. This project
wires CloudTrail into CloudWatch Logs, adds metric filters that turn specific
dangerous actions into numeric metrics, attaches alarms to those metrics, and
routes alarm notifications to email via SNS.

The result: within roughly 1–3 minutes of a root login or a bucket deletion
happening anywhere in the account, a designated email address receives an
alert.

---

## 2. Architecture Diagram

```
                     AWS API Call
                          │
                          ▼
                     ┌──────────┐
                     │CloudTrail│  (multi-region, global service events on)
                     └────┬─────┘
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
        ┌───────────┐         ┌───────────────────┐
        │ S3 Bucket │         │ CloudWatch Log     │
        │ (durable, │         │ Group              │
        │ versioned,│         │ (real-time stream) │
        │ encrypted)│         └─────────┬──────────┘
        └───────────┘                   │
                                         ▼
                          ┌────────────────────────────┐
                          │ CloudWatch Metric Filters   │
                          │  • DeleteBucket pattern     │
                          │  • Root ConsoleLogin pattern│
                          └─────────────┬───────────────┘
                                         ▼
                          ┌────────────────────────────┐
                          │ CloudWatch Metrics          │
                          │  (SecurityMonitoring ns)    │
                          └─────────────┬───────────────┘
                                         ▼
                          ┌────────────────────────────┐
                          │ CloudWatch Alarms           │
                          │  threshold >= 1, period 60s │
                          └─────────────┬───────────────┘
                                         ▼
                          ┌────────────────────────────┐
                          │ SNS Topic                   │
                          │  security-alerts             │
                          └─────────────┬───────────────┘
                                         ▼
                          ┌────────────────────────────┐
                          │ Email Notification          │
                          └────────────────────────────┘
```

---

## 3. AWS Services Used

| Service | Role in this project |
|---|---|
| AWS CloudTrail | Records all account API activity (management + global service events) |
| Amazon S3 | Durable, encrypted, versioned long-term storage for CloudTrail log files |
| Amazon CloudWatch Logs | Real-time, searchable copy of CloudTrail events; source for metric filters |
| Amazon CloudWatch Metric Filters | Convert matching log patterns into numeric metrics |
| Amazon CloudWatch Alarms | Evaluate metrics against a threshold and trigger notifications |
| Amazon SNS | Fan-out notification delivery (email in this project) |
| AWS IAM | Grants CloudTrail permission to write into CloudWatch Logs (least privilege) |

---

## 4. Folder Structure

```
terraform-cloudtrail-demo/            # the Terraform code
├── versions.tf                  # Terraform & provider version constraints
├── provider.tf                  # AWS provider config + account/region data sources
├── backend.tf                   # Remote S3 + DynamoDB state backend (partial config)
├── backend.hcl.example          # Copy to backend.hcl and fill in bucket/table
├── variables.tf                 # All configurable inputs
├── terraform.tfvars.example     # Copy to terraform.tfvars and fill in real values
├── locals.tf                    # Derived/shared values (naming, tags)
├── main.tf                      # File map / index (resources live in service-area files below)
├── iam.tf                       # IAM role/policy: CloudTrail -> CloudWatch Logs
├── s3.tf                        # CloudTrail S3 bucket, policy, encryption, versioning, lifecycle
├── cloudtrail.tf                # The trail itself + its CloudWatch Log Group
├── cloudwatch.tf                # Metric filters + alarms for both scenarios
├── sns.tf                       # SNS topic, topic policy, email subscriptions
└── outputs.tf                   # Post-apply outputs for verification/handoff

terraform-cloudtrail-demo-docs/       # this folder — all documentation
├── README.md                    # This file — architecture, layout, quick local run
├── GUIDE.md                     # Concept-by-concept explanation of why each piece exists
├── EXPLANATION_AND_USAGE.md     # File-by-file walkthrough of every .tf file
└── END_TO_END.md                # Full operational runbook: deploy, test, verify, destroy
```

CI lives at the repo root: `.github/workflows/cloudtrail-deploy.yml` — this
project shares that convention with the other two example roots
(`kinesis_log/`, `Terra_example/`), each with its own workflow file rather
than a nested `.github/` per example.

---

## 5. Prerequisites

- **Terraform** >= 1.6.0 ([install guide](https://developer.hashicorp.com/terraform/install))
- **AWS CLI** v2, configured with credentials (`aws configure` or SSO)
- An AWS account/sandbox where you have permission to create the resources below
- An email address you can access, to confirm the SNS subscription

### IAM Permissions Required to Deploy This Project

The identity running `terraform apply` needs permissions to create/manage:
- `cloudtrail:*` (or scoped: CreateTrail, PutEventSelectors, StartLogging, DescribeTrails, DeleteTrail, GetTrailStatus)
- `s3:CreateBucket`, `s3:PutBucketPolicy`, `s3:PutBucketVersioning`, `s3:PutEncryptionConfiguration`, `s3:PutLifecycleConfiguration`, `s3:PutBucketPublicAccessBlock`, `s3:DeleteBucket` (for destroy)
- `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:DeleteLogGroup`, `logs:PutMetricFilter`, `logs:DeleteMetricFilter`
- `cloudwatch:PutMetricAlarm`, `cloudwatch:DeleteAlarms`
- `sns:CreateTopic`, `sns:SetTopicAttributes`, `sns:Subscribe`, `sns:DeleteTopic`
- `iam:CreateRole`, `iam:CreatePolicy`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:DeleteRole`, `iam:DeletePolicy`, `iam:PassRole`

If the deploying identity is a scoped (non-admin) role rather than an AWS
admin, build a custom policy from the list above — note that
`permissions/terraform-deploy-policy.json` in this repo currently only
covers `kinesis_log/`'s resources, not this project's.

---

## 6. Remote State Backend

This project uses the **same S3 + DynamoDB backend** already set up for
`kinesis_log/` and `Terra_example/` — no separate bucket or table needed.
`backend.tf`'s `key = "sec-monitoring/terraform.tfstate"` keeps this root's
state file separate from the other two in the same bucket. Copy
`backend.hcl.example` to `backend.hcl` (gitignored) and fill in the same
`bucket`/`dynamodb_table` values used for the other examples.

---

## 7. Deployment Steps (local)

Run these from the code folder, `terraform-cloudtrail-demo/` (one level up
from this doc folder):
```bash
cd ../terraform-cloudtrail-demo
```

### 7.1 Configure variables
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set alarm_notification_emails to a real address you control
```

### 7.2 Initialize (pointing at the shared backend)
```bash
cp backend.hcl.example backend.hcl
# Edit backend.hcl: fill in the same bucket/dynamodb_table as the other examples
terraform init -backend-config=backend.hcl
```

### 7.3 Plan
```bash
terraform plan -var-file="terraform.tfvars"
```
Read-only. Shows exactly what will be created — review the resource count and names before proceeding.

### 7.4 Apply
```bash
terraform apply -var-file="terraform.tfvars"
```
Type `yes` when prompted. Deployment typically completes in 60–120 seconds.

---

## 8. Deployment via GitHub Actions

The workflow at `.github/workflows/cloudtrail-deploy.yml` runs apply or
destroy on demand (`workflow_dispatch`), mirroring the local flow above.

### 8.1 Required GitHub Secrets

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key for an IAM user/role with the permissions listed in Section 5 |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |
| `TF_STATE_BUCKET` | Same state bucket already used by `kinesis_log`/`Terra_example` |
| `TF_STATE_DYNAMODB_TABLE` | Same lock table already used by `kinesis_log`/`Terra_example` |
| `ALARM_NOTIFICATION_EMAILS` | A Terraform list literal, e.g. `["security-team@example.com"]` |

### 8.2 Running the workflow
Go to **Actions → CloudTrail Security Monitoring Deploy → Run workflow**,
choose `action`: `apply` or `destroy`.

### 8.3 What the workflow does
On `apply`: checks out the repo, sets up Terraform, configures AWS
credentials for `eu-west-2`, initializes against the shared remote backend,
runs `plan` then `apply -auto-approve`, and prints `terraform output`. If
apply fails, it automatically empties the CloudTrail S3 bucket and destroys
to avoid leaving a half-deployed, costed stack behind.

On `destroy`: empties the CloudTrail S3 bucket (Terraform won't force-delete
a non-empty bucket by default), then runs `terraform destroy -auto-approve`.

Testing both detection scenarios is a manual step, done after deployment —
see `END_TO_END.md`.

---

## 9. Testing, Verification, and Cleanup

See `END_TO_END.md` for: confirming the SNS subscription, triggering both
test scenarios (DeleteBucket and root login), verifying via the AWS CLI at
each stage of the pipeline, troubleshooting, and the full destroy/teardown
order.
