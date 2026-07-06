output "kinesis_stream_arn" {
  description = "ARN of the Kinesis Data Stream receiving CloudWatch Logs"
  value       = aws_kinesis_stream.log_stream.arn
}

output "firehose_delivery_stream_arn" {
  description = "ARN of the Firehose delivery stream writing to S3"
  value       = aws_kinesis_firehose_delivery_stream.to_s3.arn
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket storing delivered logs"
  value       = aws_s3_bucket.log_destination.bucket
}

output "cloudwatch_subscription_filter_name" {
  description = "Name of the CloudWatch Logs subscription filter"
  value       = aws_cloudwatch_log_subscription_filter.to_kinesis.name
}
