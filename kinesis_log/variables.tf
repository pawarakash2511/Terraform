variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2"
}

variable "name_prefix" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "cwlogs"
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket that will store log data (must be globally unique)"
  type        = string
}

variable "log_retention_days" {
  description = "Number of days to retain log objects in S3 before expiry"
  type        = number
  default     = 90
}

variable "cloudwatch_log_group_name" {
  description = "Name of the existing CloudWatch Log Group to subscribe to"
  type        = string
}

variable "log_filter_pattern" {
  description = "CloudWatch Logs filter pattern. Empty string matches all log events."
  type        = string
  default     = ""
}

variable "kinesis_shard_count" {
  description = "Number of shards for the Kinesis Data Stream. Each shard = 1MB/s in, 2MB/s out."
  type        = number
  default     = 1
}

variable "firehose_buffer_size_mb" {
  description = "Firehose buffer size in MB before flushing to S3 (1-128)"
  type        = number
  default     = 5
}

variable "firehose_buffer_interval_seconds" {
  description = "Firehose buffer interval in seconds before flushing to S3 (60-900)"
  type        = number
  default     = 300
}

variable "tags" {
  description = "Tags applied to all taggable resources"
  type        = map(string)
  default     = {}
}
