# ---------------------------------------------------------------------------
# cloudwatch.tf
#
# WHY THIS FILE EXISTS:
# Metric filters are what turn a firehose of raw CloudTrail JSON log lines
# into an actionable number. Without a metric filter, log data just sits in
# CloudWatch Logs, readable but not actively monitored. Alarms then watch
# that number and decide when to notify a human via SNS.
#
# WHAT AWS DOES INTERNALLY:
# Every time a new log event is written into the CloudWatch Log Group
# (streamed there by CloudTrail, per cloudtrail.tf), CloudWatch Logs
# evaluates that event against every metric filter's pattern in near real
# time. On a match, it publishes a data point (value = 1, per this
# project's metric_transformation) into the named CloudWatch metric. The
# alarm attached to that metric then evaluates on its own schedule
# (period/evaluation_periods) and transitions to ALARM state if the
# threshold condition is met, which invokes any configured alarm_actions
# (here, publishing to the SNS topic in sns.tf).
# ---------------------------------------------------------------------------


# =============================================================================
# SCENARIO 1: Detect S3 Bucket Deletion (DeleteBucket API)
# =============================================================================
#
# WHY THIS MATTERS:
# Deleting an S3 bucket is often irreversible (unless versioning + MFA
# delete are configured) and can represent data destruction, either
# malicious or accidental. This is a high-value, low-noise signal — bucket
# deletion should be rare enough that every occurrence deserves a human
# looking at it.
#
# PATTERN LOGIC:
# Matches any CloudTrail event where eventSource is the S3 API and
# eventName is exactly "DeleteBucket". Using eventSource narrows this
# to only the actual S3 DeleteBucket API call, avoiding any accidental
# collision with a similarly-named action in a different service.

resource "aws_cloudwatch_log_metric_filter" "delete_bucket" {
  name           = "${local.name_prefix}-delete-bucket-filter"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{ ($.eventSource = \"s3.amazonaws.com\") && ($.eventName = \"DeleteBucket\") }"

  metric_transformation {
    name          = "DeleteBucketEventCount"
    namespace     = "SecurityMonitoring"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "delete_bucket" {
  alarm_name        = "${local.name_prefix}-delete-bucket-alarm"
  alarm_description = "Fires when any S3 bucket is deleted in this account. Bucket deletion is a rare, high-impact action that should always be reviewed."

  namespace   = "SecurityMonitoring"
  metric_name = "DeleteBucketEventCount"
  statistic   = "Sum"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.metric_alarm_threshold
  period              = var.metric_alarm_period_seconds
  evaluation_periods  = var.metric_alarm_evaluation_periods

  # "notBreaching" treats gaps in data (i.e. no DeleteBucket events at all)
  # as normal/healthy, rather than flipping the alarm to INSUFFICIENT_DATA.
  # For a security alarm, silence should mean "nothing happened," not
  # "something might be wrong with monitoring."
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]

  tags = local.common_tags
}


# =============================================================================
# SCENARIO 2: Detect Root Account Console Login
# =============================================================================
#
# WHY THIS MATTERS:
# The AWS root user has unrestricted, unrevocable permissions over the
# entire account and cannot be constrained by IAM policy. Best practice is
# that root is never used for day-to-day operations — its use should be
# rare (e.g. certain billing changes) and always intentional. ANY root
# login is therefore a meaningful security event, whether it is legitimate
# admin activity or a sign of credential compromise.
#
# PATTERN LOGIC:
# Matches only when BOTH conditions are true:
#   1. eventName = "ConsoleLogin"   -> a console sign-in occurred
#   2. userIdentity.type = "Root"   -> the identity that signed in was
#                                      specifically the root user
# This second condition is what prevents ordinary IAM user or federated
# logins from being counted — the spec requires that ONLY root logins
# trigger this alarm, not IAM user logins.

resource "aws_cloudwatch_log_metric_filter" "root_login" {
  name           = "${local.name_prefix}-root-login-filter"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{ ($.eventName = \"ConsoleLogin\") && ($.userIdentity.type = \"Root\") }"

  metric_transformation {
    name          = "RootLoginEventCount"
    namespace     = "SecurityMonitoring"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_login" {
  alarm_name        = "${local.name_prefix}-root-login-alarm"
  alarm_description = "Fires whenever the AWS root account signs in to the console. Root should not be used for routine operations — every occurrence should be reviewed."

  namespace   = "SecurityMonitoring"
  metric_name = "RootLoginEventCount"
  statistic   = "Sum"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.metric_alarm_threshold
  period              = var.metric_alarm_period_seconds
  evaluation_periods  = var.metric_alarm_evaluation_periods

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]

  tags = local.common_tags
}
