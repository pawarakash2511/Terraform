# ---------------------------------------------------------------------------
# main.tf
#
# WHY THIS FILE EXISTS (AND WHY IT'S NEARLY EMPTY):
# Terraform does not require a single entry-point file — it loads every
# .tf file in the working directory and merges them into one configuration
# graph. This project deliberately splits resources by AWS service area
# (s3.tf, iam.tf, cloudtrail.tf, cloudwatch.tf, sns.tf) rather than putting
# everything in one large main.tf, because it is significantly easier to
# navigate, review in pull requests, and hand off to someone unfamiliar
# with the project. main.tf is kept as a lightweight index/reference point
# only.
#
# FILE MAP:
#   versions.tf   -> Terraform & provider version constraints
#   provider.tf   -> AWS provider configuration + account/region data sources
#   variables.tf  -> All configurable inputs
#   locals.tf     -> Derived/computed values shared across files
#   s3.tf         -> CloudTrail log storage bucket, policy, encryption, lifecycle
#   iam.tf        -> IAM role/policy allowing CloudTrail to write to CloudWatch Logs
#   cloudtrail.tf -> The CloudTrail trail itself + its CloudWatch Log Group
#   cloudwatch.tf -> Metric filters and alarms for the two detection scenarios
#   sns.tf        -> SNS topic, topic policy, and email subscriptions
#   outputs.tf    -> Values surfaced after apply for verification/handoff
# ---------------------------------------------------------------------------
