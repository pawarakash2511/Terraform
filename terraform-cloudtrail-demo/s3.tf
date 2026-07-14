# ---------------------------------------------------------------------------
# s3.tf
#
# WHY THIS FILE EXISTS:
# CloudTrail requires a durable, tamper-evident storage destination for the
# raw log files it produces. AWS does not let CloudTrail write directly to
# CloudWatch Logs as its primary store — S3 is the mandatory long-term
# record; CloudWatch Logs (configured in cloudwatch.tf) is a secondary,
# real-time-searchable copy used for alerting.
#
# WHAT AWS DOES INTERNALLY:
# Every ~5 minutes (or sooner under load), CloudTrail batches recorded API
# events into a compressed JSON file and calls s3:PutObject to write it
# under a partitioned key structure:
#   AWSLogs/<account-id>/CloudTrail/<region>/<year>/<month>/<day>/<file>.json.gz
# This bucket policy is what authorizes the CloudTrail service principal to
# perform that PutObject call — without it, CloudTrail silently fails to
# deliver logs to S3.
# ---------------------------------------------------------------------------

# The bucket itself. Named uniquely per account using the account ID suffix,
# since S3 bucket names are globally unique across ALL AWS accounts.
resource "aws_s3_bucket" "cloudtrail" {
  bucket = "${local.name_prefix}-cloudtrail-logs-${local.account_id}"

  tags = merge(local.common_tags, {
    Purpose = "CloudTrail log storage"
  })
}

# Blocks all forms of public access at the bucket level. CloudTrail logs
# contain sensitive account activity (API calls, IAM identities, source
# IPs) and must never be publicly reachable. This is also a hard
# requirement of CIS AWS Foundations Benchmark control 2.1.5.
resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enables versioning so that even if a log object were somehow overwritten
# or deleted, prior versions remain recoverable. This directly supports
# log integrity / non-repudiation requirements common in SOC 2 and PCI-DSS.
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Default server-side encryption (SSE-S3/AES256) applied to every object
# written to this bucket, without relying on the writer (CloudTrail) to
# specify encryption on each PutObject call.
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Lifecycle rule to transition/expire old log files automatically, rather
# than accumulating indefinitely (and indefinitely billing storage costs).
# Adjust s3_log_retention_days to match your organization's compliance
# retention requirement.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-old-cloudtrail-logs"
    status = "Enabled"

    filter {
      prefix = "AWSLogs/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 180
      storage_class = "GLACIER"
    }

    expiration {
      days = var.s3_log_retention_days
    }
  }
}

# ---------------------------------------------------------------------------
# Bucket policy: grants the CloudTrail SERVICE PRINCIPAL (not an IAM role)
# permission to check the bucket ACL and write log objects. This is a
# resource-based policy attached to the bucket itself, separate from the
# IAM role/policy defined in iam.tf (which governs CloudTrail's permission
# to write into CloudWatch Logs, a different destination).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cloudtrail_bucket_policy" {

  # Required so CloudTrail can verify the bucket exists and check ownership
  # settings before it attempts to write to it.
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${local.region}:${local.account_id}:trail/${local.name_prefix}-trail"]
    }
  }

  # Grants the actual write permission. Scoped narrowly to this account's
  # log prefix only (AWSLogs/<account-id>/*), and requires the
  # bucket-owner-full-control ACL condition so CloudTrail cannot write
  # objects that the bucket owner would be unable to manage/delete later.
  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${local.region}:${local.account_id}:trail/${local.name_prefix}-trail"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy.json
}
