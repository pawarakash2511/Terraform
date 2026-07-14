# ---------------------------------------------------------------------------
# provider.tf
#
# WHY THIS FILE EXISTS:
# Configures the AWS provider — the plugin Terraform uses to translate HCL
# resource blocks into actual AWS API calls (via the AWS SDK under the hood).
# Region is externalized to a variable so this project can be redeployed
# into any region without editing code — only tfvars changes.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  # default_tags apply automatically to every resource this provider creates
  # that supports tagging. This guarantees consistent cost-allocation and
  # ownership tags without needing to repeat them on every single resource.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Used throughout the project to build ARNs and bucket policies dynamically
# rather than hardcoding an AWS account ID.
data "aws_caller_identity" "current" {}

# Used to build region-aware ARNs and resource names without hardcoding
# the region string anywhere else in the project.
data "aws_region" "current" {}
