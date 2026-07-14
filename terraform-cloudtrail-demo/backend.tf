# ---------------------------------------------------------------------------
# backend.tf
#
# WHY THIS FILE EXISTS:
# By default, Terraform stores state (its record of what currently exists)
# in a local file: terraform.tfstate, sitting on whichever machine ran
# apply. That's fine solo, but breaks down the moment more than one person
# or a CI pipeline needs to run Terraform against the same infrastructure —
# there is no shared source of truth, and no protection against two runs
# writing state at the same time.
#
# This project uses an S3 backend for centralized, shared state storage,
# with a DynamoDB table for state locking — preventing two concurrent
# `terraform apply` runs (e.g. two GitHub Actions runs triggered close
# together) from corrupting state by writing to it simultaneously.
#
# WHY THIS CONFIGURATION IS "PARTIAL":
# The bucket and dynamodb_table values are deliberately left blank here.
# They are supplied at `terraform init` time via -backend-config flags
# (see .github/workflows/terraform.yml), sourced from GitHub Secrets.
# This means the same codebase can point at different state backends per
# environment (dev/staging/prod) without editing this file — only the
# init command's flags change.
#
# IMPORTANT — BOOTSTRAP REQUIREMENT:
# The S3 bucket and DynamoDB table referenced here must already exist
# BEFORE the first `terraform init` runs against this backend — Terraform
# cannot create the very storage it needs in order to store its own state
# (a chicken-and-egg problem). See bootstrap/ for a one-time-use Terraform
# config that creates exactly these two resources using local state.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    # bucket          -> supplied via -backend-config="bucket=..." at init time
    # dynamodb_table  -> supplied via -backend-config="dynamodb_table=..." at init time
    key     = "sec-monitoring/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
