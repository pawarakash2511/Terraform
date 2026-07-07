##############################################
# Read existing AWS resources instead of creating new ones
##############################################

# The account's default VPC — every AWS account has one unless it was
# explicitly deleted, so this avoids creating a whole new VPC just to
# launch one example VM.
data "aws_vpc" "default" {
  default = true
}

# Existing subnets inside that default VPC.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Most recent Amazon Linux 2023 AMI, owned by Amazon — read at plan/apply
# time instead of hardcoding an AMI ID that goes stale as AWS ships updates.
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
