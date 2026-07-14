resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_metric_filter" "delete_bucket" {
  name           = "DeleteBucket"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ ($.eventName = DeleteBucket) }"

  metric_transformation {
    name      = "DeleteBucketCount"
    namespace = "Security"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "delete_bucket" {
  alarm_name          = "DeleteBucketAlarm"
  namespace           = "Security"
  metric_name         = "DeleteBucketCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  alarm_actions = [aws_sns_topic.security.arn]
}
