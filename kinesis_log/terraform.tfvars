aws_region  = "eu-west-2"
name_prefix = "cwlogs"

cloudwatch_log_group_name = "/test/kinesis-pipeline"
log_filter_pattern        = ""

kinesis_shard_count               = 1
firehose_buffer_size_mb            = 1
firehose_buffer_interval_seconds   = 60
log_retention_days                 = 90

# s3_bucket_name intentionally left OUT — comes from GitHub secret in CI,
# or export TF_VAR_s3_bucket_name locally when testing by hand

tags = {
  Project     = "kinesis-log-pipeline"
  Environment = "test"
  ManagedBy   = "terraform"
}
