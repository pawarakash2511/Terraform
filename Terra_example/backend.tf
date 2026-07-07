terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    key     = "terra_example/terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
    # bucket + dynamodb_table are supplied at `terraform init` time, and
    # deliberately reuse the same state bucket/lock table as kinesis_log —
    # one bucket per AWS account, one state key per Terraform root is the
    # standard pattern. See backend.hcl.example and Terra_example_doc/.
  }
}
