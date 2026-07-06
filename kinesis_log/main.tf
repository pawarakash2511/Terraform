##############################################
# CloudWatch Logs -> Kinesis Data Stream -> Kinesis Firehose -> S3
##############################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key     = "kinesis_log/terraform.tfstate"
    region  = "ap-south-1"
    encrypt = true
    # bucket + dynamodb_table are account-specific and supplied at
    # `terraform init` time — see backend.hcl.example and the README's
    # "Remote state backend setup" section.
  }
}

provider "aws" {
  region = var.aws_region
}

##############################################
# 1. S3 bucket - final destination for logs
##############################################

resource "aws_s3_bucket" "log_destination" {
  bucket = var.s3_bucket_name
}

resource "aws_s3_bucket_lifecycle_configuration" "log_destination" {
  bucket = aws_s3_bucket.log_destination.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {} # applies to every object in the bucket

    expiration {
      days = var.log_retention_days
    }
  }
}

##############################################
# 2. Kinesis Data Stream - the streaming layer
##############################################

resource "aws_kinesis_stream" "log_stream" {
  name             = "${var.name_prefix}-log-stream"
  shard_count      = var.kinesis_shard_count
  retention_period = 24 # hours; raise this if you need longer replay

  stream_mode_details {
    stream_mode = "PROVISIONED" # switch to ON_DEMAND if traffic is unpredictable
  }

  tags = var.tags
}

##############################################
# 3. IAM role that CloudWatch Logs assumes to write into Kinesis
##############################################

data "aws_iam_policy_document" "cwl_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cwl_to_kinesis_role" {
  name               = "${var.name_prefix}-cwl-to-kinesis-role"
  assume_role_policy = data.aws_iam_policy_document.cwl_assume_role.json
}

data "aws_iam_policy_document" "cwl_to_kinesis_policy" {
  statement {
    effect = "Allow"
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords"
    ]
    resources = [aws_kinesis_stream.log_stream.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.cwl_to_kinesis_role.arn]
  }
}

resource "aws_iam_role_policy" "cwl_to_kinesis_policy" {
  name   = "${var.name_prefix}-cwl-to-kinesis-policy"
  role   = aws_iam_role.cwl_to_kinesis_role.id
  policy = data.aws_iam_policy_document.cwl_to_kinesis_policy.json
}

##############################################
# 4. CloudWatch Logs subscription filter - the actual wiring
##############################################

resource "aws_cloudwatch_log_subscription_filter" "to_kinesis" {
  name            = "${var.name_prefix}-to-kinesis"
  log_group_name  = var.cloudwatch_log_group_name
  filter_pattern  = var.log_filter_pattern # "" means match everything
  destination_arn = aws_kinesis_stream.log_stream.arn
  role_arn        = aws_iam_role.cwl_to_kinesis_role.arn
  distribution    = "ByLogStream"
}

##############################################
# 5. IAM role that Firehose assumes to read Kinesis + write S3
##############################################

data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose_role" {
  name               = "${var.name_prefix}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json
}

data "aws_iam_policy_document" "firehose_policy" {
  statement {
    effect = "Allow"
    actions = [
      "kinesis:DescribeStream",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards"
    ]
    resources = [aws_kinesis_stream.log_stream.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]
    resources = [
      aws_s3_bucket.log_destination.arn,
      "${aws_s3_bucket.log_destination.arn}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws/kinesisfirehose/*"]
  }
}

resource "aws_iam_role_policy" "firehose_policy" {
  name   = "${var.name_prefix}-firehose-policy"
  role   = aws_iam_role.firehose_role.id
  policy = data.aws_iam_policy_document.firehose_policy.json
}

##############################################
# 6. Kinesis Firehose delivery stream - reads Kinesis, writes S3
##############################################

resource "aws_cloudwatch_log_group" "firehose_error_logs" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}-to-s3"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose_error_log_stream" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose_error_logs.name
}

resource "aws_kinesis_firehose_delivery_stream" "to_s3" {
  name        = "${var.name_prefix}-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.log_stream.arn
    role_arn            = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.log_destination.arn

    prefix              = "raw/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = var.firehose_buffer_size_mb
    buffering_interval  = var.firehose_buffer_interval_seconds

    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose_error_logs.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_error_log_stream.name
    }
  }

  tags = var.tags
}
