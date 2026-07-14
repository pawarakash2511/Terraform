# ---------------------------------------------------------------------------
# cloudtrail.tf
#
# WHY THIS FILE EXISTS:
# This is the source of truth for "what happened in this AWS account."
# CloudTrail records every management-plane API call (console, CLI, SDK,
# and calls made by other AWS services on your behalf) as a structured
# JSON event. Everything downstream in this project (metric filters,
# alarms, SNS) depends entirely on CloudTrail being correctly configured
# to deliver events to BOTH S3 and CloudWatch Logs.
#
# WHAT AWS DOES INTERNALLY:
# Once StartLogging is active, every API call in the account is captured
# by the CloudTrail service in near real time, written first to an
# internal durable queue, then delivered in batches to the configured
# destinations (S3 always; CloudWatch Logs only if configured, as we do
# here via cloud_watch_logs_group_arn / cloud_watch_logs_role_arn).
# ---------------------------------------------------------------------------

# The CloudWatch Log Group that will receive a real-time copy of every
# CloudTrail event. This is what metric filters (cloudwatch.tf) read from.
# CloudTrail cannot stream directly into an arbitrary log group without
# this being created first and referenced by both the trail and the IAM
# role in iam.tf.
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudtrail" "main" {
  name           = "${local.name_prefix}-trail"
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  # Captures events from ALL regions, not just the one this provider is
  # configured for. Without this, an attacker (or misconfigured automation)
  # operating in an unmonitored region would go completely undetected —
  # this is CIS AWS Foundations Benchmark control 3.1's explicit requirement.
  is_multi_region_trail = true

  # Captures global service events (IAM, STS, CloudFront, Route53) which
  # are not tied to any single region. Root login and IAM policy changes
  # — the two scenarios in this project — are both global service events,
  # so this MUST be true or Scenario 2 (Root Login) will not be detected.
  include_global_service_events = true

  # Enables SHA-256 digest files that let you cryptographically verify
  # CloudTrail log files have not been tampered with or deleted after
  # delivery. This satisfies log-integrity requirements in most compliance
  # frameworks (CIS 3.2, SOC 2, PCI-DSS).
  enable_log_file_validation = true

  # Wires this trail to also stream into the CloudWatch Log Group above,
  # using the IAM role defined in iam.tf to authorize the write.
  # This is the connection point that makes real-time metric filters
  # possible — without these two lines, CloudTrail would ONLY write to S3,
  # and none of the alerting in this project would function.
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch_role.arn

  # Explicit dependency: the bucket policy MUST exist before CloudTrail is
  # created, or trail creation fails validation (CloudTrail checks that it
  # is authorized to write to the bucket at creation time, not just at
  # first log delivery).
  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_iam_role_policy_attachment.cloudtrail_cloudwatch_attachment
  ]

  tags = local.common_tags
}
