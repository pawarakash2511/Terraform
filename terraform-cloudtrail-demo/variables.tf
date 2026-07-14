# ---------------------------------------------------------------------------
# variables.tf
#
# WHY THIS FILE EXISTS:
# Centralizes every configurable input. This is what makes the project
# reusable across accounts/environments/clients without touching any
# resource code — only terraform.tfvars changes.
# ---------------------------------------------------------------------------

variable "project_name" {
  description = "Short name used as a prefix for all resource names (e.g. S3 bucket, IAM role, log group)."
  type        = string
  default     = "sec-monitoring"
}

variable "environment" {
  description = "Deployment environment identifier, used in tags (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into. CloudTrail is created as multi-region regardless of this setting, but the trail's home region and all regional resources (log group, alarms, SNS) live here."
  type        = string
  default     = "eu-west-2"
}

variable "log_retention_days" {
  description = "Number of days CloudWatch Logs retains CloudTrail log events. AWS allows specific values only (1,3,5,7,14,30,60,90,120,150,180,365,400,545,731,1096,1827,2192,2557,2922,3288,3653)."
  type        = number
  default     = 90
}

variable "s3_log_retention_days" {
  description = "Number of days to retain raw CloudTrail log files in S3 before they are transitioned/expired via lifecycle rule. Set higher for compliance retention requirements (e.g. 365+ for SOC2/PCI)."
  type        = number
  default     = 365
}

variable "alarm_notification_emails" {
  description = "List of email addresses to subscribe to the SNS security alerts topic. Each address will receive an AWS confirmation email that must be manually accepted before notifications are delivered."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.alarm_notification_emails) > 0
    error_message = "At least one email address must be provided in alarm_notification_emails, or no one will receive alerts."
  }
}

variable "metric_alarm_period_seconds" {
  description = "The evaluation period, in seconds, for each CloudWatch alarm. 60 seconds gives near real-time detection at the cost of slightly higher CloudWatch charges versus a longer period."
  type        = number
  default     = 60
}

variable "metric_alarm_evaluation_periods" {
  description = "Number of consecutive periods the metric must breach the threshold before the alarm fires. 1 means immediate alerting on the first matching event — appropriate for security events, where waiting for a trend is undesirable."
  type        = number
  default     = 1
}

variable "metric_alarm_threshold" {
  description = "The metric value that triggers ALARM state. A single matching CloudTrail event should always alert, so this defaults to 1."
  type        = number
  default     = 1
}
