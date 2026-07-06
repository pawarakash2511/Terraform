# CloudWatch Logs → Kinesis → S3

Terraform module that streams CloudWatch Logs through a Kinesis Data Stream
into S3 via Kinesis Firehose.

## Flow

```
CloudWatch Log Group
   │  (subscription filter, filters events in near-real-time)
   ▼
Kinesis Data Stream          <- raw streaming layer, replayable for 24h
   │
   ▼
Kinesis Firehose             <- buffers records, then batch-writes to S3
   │
   ▼
S3 Bucket (gzip'd, partitioned by date)
```

## Why this shape

- **CloudWatch Logs → Kinesis Data Stream**: gives you a real, replayable
  stream. Useful if later you want another consumer off the same stream
  (e.g. a Lambda that fires alerts on ERROR lines) without touching the
  logging side again.
- **Kinesis Data Stream → Firehose → S3**: Firehose is the piece that
  actually knows how to batch and write files to S3. A raw Kinesis stream
  has no native "write to S3" capability — you always need Firehose or a
  custom Lambda consumer for that.
- If you don't need the replay/multi-consumer flexibility, you can drop the
  Data Stream entirely and point the CloudWatch Logs subscription filter
  straight at Firehose (`destination_arn` -> Firehose ARN instead of Kinesis
  stream ARN, with `logs.<region>.amazonaws.com` trust changed accordingly).
  Ask if you want that simpler 2-tier version instead.

## Usage

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in:
   - `s3_bucket_name` — must be globally unique across all of AWS
   - `cloudwatch_log_group_name` — must already exist (this module does not
     create the log group itself, since it's usually created by whatever
     app/service is logging)
2. `terraform init`
3. `terraform plan`
4. `terraform apply`

## Notes for the client

- **Cost drivers**: Kinesis shard count (each shard ≈ $0.015/hour + $0.014
  per million PUT payload units), and Firehose (~$0.029 per GB ingested).
  S3 storage is on top of that. For low-to-medium log volume, 1 shard is
  usually enough — watch `IncomingBytes`/`IncomingRecords` CloudWatch
  metrics on the stream and scale shard count if you see throttling.
- **Filter pattern**: leaving `log_filter_pattern` empty ships every log
  event. If the client only cares about errors/warnings, set a filter
  pattern (e.g. `"ERROR"` or a JSON metric filter) to cut ingestion cost.
- **Buffering**: Firehose flushes to S3 either every
  `firehose_buffer_interval_seconds` or when `firehose_buffer_size_mb` is
  hit, whichever comes first. Shorter interval = fresher data in S3, more
  (smaller) S3 objects. Longer interval = fewer, larger objects, cheaper S3
  request costs.
- **Retention**: the Kinesis stream holds data for 24h (adjustable) for
  replay purposes; S3 is the long-term store, with lifecycle expiry set via
  `log_retention_days`.
