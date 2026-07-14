# ---------------------------------------------------------------------------
# versions.tf
#
# WHY THIS FILE EXISTS:
# Pinning Terraform core and provider versions prevents "it worked on my
# machine" drift. Without this, a teammate running a newer Terraform CLI
# or provider release could get subtly different behavior (new default
# arguments, deprecated fields, renamed attributes), which is a common
# source of hard-to-debug production incidents.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # Latest stable AWS provider major version at time of writing
    }
  }
}
