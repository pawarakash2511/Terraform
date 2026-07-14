# ---------------------------------------------------------------------------
# outputs.tf
#
# WHY THIS FILE EXISTS:
# Surfaces the identifiers you need immediately after `terraform apply` to
# verify the deployment and to hand off to teammates without them having
# to dig through the AWS console to find ARNs/names.
# ---------------------------------------------------------------------------

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail trail created by this project."
  value       = aws_cloudtrail.main.arn
}

output "cloudtrail_s3_bucket_name" {
  description = "Name of the S3 bucket storing raw CloudTrail log files."
  value       = aws_s3_bucket.cloudtrail.id
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch Log Group receiving the real-time CloudTrail event stream. Use this to run Logs Insights queries or manually inspect raw events."
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic that all alarms publish to."
  value       = aws_sns_topic.security_alerts.arn
}

output "delete_bucket_alarm_name" {
  description = "Name of the CloudWatch alarm for Scenario 1 (S3 DeleteBucket detection)."
  value       = aws_cloudwatch_metric_alarm.delete_bucket.alarm_name
}

output "root_login_alarm_name" {
  description = "Name of the CloudWatch alarm for Scenario 2 (Root console login detection)."
  value       = aws_cloudwatch_metric_alarm.root_login.alarm_name
}

output "pending_email_confirmations" {
  description = "Email addresses subscribed to SNS. REMINDER: each one must click the AWS confirmation link before it will receive any alert emails."
  value       = var.alarm_notification_emails
}
