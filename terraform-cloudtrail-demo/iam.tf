# ---------------------------------------------------------------------------
# iam.tf
#
# WHY THIS FILE EXISTS:
# CloudTrail's write access to S3 (s3.tf) is authorized by a bucket policy,
# but CloudTrail's write access to CloudWatch Logs works differently — it
# requires CloudTrail to ASSUME AN IAM ROLE that grants logs:PutLogEvents.
# Without this role, CloudTrail will continue delivering to S3 successfully,
# but CloudWatch Logs will remain empty — which means metric filters (the
# whole point of this project) will never fire. This is one of the most
# common misconfigurations in real deployments.
#
# WHAT AWS DOES INTERNALLY:
# CloudTrail calls sts:AssumeRole against this role for every log delivery
# batch, then uses the resulting temporary credentials to call
# logs:CreateLogStream and logs:PutLogEvents against the specific log group
# ARN this policy authorizes.
# ---------------------------------------------------------------------------

# Trust policy: only the CloudTrail service principal may assume this role.
# This is intentionally scoped to nothing else — no human, no other AWS
# service can use this role.
data "aws_iam_policy_document" "cloudtrail_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_cloudwatch_role" {
  name               = "${local.name_prefix}-cloudtrail-to-cwl-role"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume_role.json

  tags = local.common_tags
}

# Permissions policy: least-privilege, scoped to exactly the one log group
# this role needs to write into (defined in cloudwatch.tf). The trailing
# ":*" allows writing to any log stream WITHIN that log group, since
# CloudTrail creates a new log stream per delivery.
data "aws_iam_policy_document" "cloudtrail_cloudwatch_permissions" {
  statement {
    sid    = "AllowCloudTrailToWriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    ]
  }
}

resource "aws_iam_policy" "cloudtrail_cloudwatch_policy" {
  name        = "${local.name_prefix}-cloudtrail-to-cwl-policy"
  description = "Allows CloudTrail to write log events into the designated CloudWatch Log Group."
  policy      = data.aws_iam_policy_document.cloudtrail_cloudwatch_permissions.json
}

# Explicit attachment resource (rather than an inline policy) so the policy
# is independently visible/manageable in the IAM console and reusable if
# ever needed elsewhere.
resource "aws_iam_role_policy_attachment" "cloudtrail_cloudwatch_attachment" {
  role       = aws_iam_role.cloudtrail_cloudwatch_role.name
  policy_arn = aws_iam_policy.cloudtrail_cloudwatch_policy.arn
}
