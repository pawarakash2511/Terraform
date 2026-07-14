# ---------------------------------------------------------------------------
# sns.tf
#
# WHY THIS FILE EXISTS:
# CloudWatch Alarms cannot email anyone directly — they can only publish a
# notification to an SNS topic. SNS is the fan-out layer: one alarm event
# published once can reach many subscribers (email here, but the same
# topic could simultaneously notify a Lambda, an SQS queue, or a chat
# integration without changing the alarm configuration at all).
#
# WHAT AWS DOES INTERNALLY:
# When an alarm's state transitions (e.g. OK -> ALARM), CloudWatch calls
# sns:Publish against this topic's ARN. SNS then delivers that message to
# every CONFIRMED subscription. Email subscriptions specifically require a
# human to click a confirmation link sent to that address before delivery
# begins — this is an AWS anti-abuse mechanism to prevent someone from
# using SNS to spam arbitrary email addresses they don't own.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "security_alerts" {
  name = "${local.name_prefix}-security-alerts"

  tags = local.common_tags
}

# Resource-based policy on the topic itself, authorizing the CloudWatch
# Alarms service to publish into it. Without this, alarms will show
# "Failed" delivery attempts in CloudWatch and no notification will ever
# be sent, with no obvious error surfaced to the person who deployed it —
# this is one of the most common silent failure points in real deployments.
data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowCloudWatchAlarmsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

# One subscription resource per email address in var.alarm_notification_emails.
# Using for_each (keyed by the email itself, via toset) rather than count
# means adding/removing one email later only affects that specific
# subscription resource, not every subscription's index/ordering.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_notification_emails)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}
