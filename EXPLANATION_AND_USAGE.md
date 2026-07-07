# Explaining `main.tf` — CloudWatch Logs → Kinesis → Firehose → S3

This document walks through the Terraform file block by block, in the order
resources are created, then shows you how to test the whole pipeline even
though you don't have real application logs yet.

---

## 1. Provider block

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

Tells Terraform "I'm talking to AWS, use provider version 5.x, and deploy
into whatever region is set in `var.aws_region`" (default `ap-south-1` in
`variables.tf`). Nothing is created here — this is just setup.

---

## 2. S3 bucket — the final destination

```hcl
resource "aws_s3_bucket" "log_destination" { ... }
resource "aws_s3_bucket_lifecycle_configuration" "log_destination" { ... }
```

Creates the bucket that will hold the archived logs, plus a **lifecycle
rule**: objects automatically get deleted after `var.log_retention_days`
(default 90 days). This is what keeps storage costs from growing forever —
without this, every log file ever written sits in S3 permanently.

---

## 3. Kinesis Data Stream — the streaming layer

```hcl
resource "aws_kinesis_stream" "log_stream" { ... }
```

This is the "pipe" CloudWatch Logs writes into. Key settings:
- `shard_count = 1` — one shard handles up to 1MB/sec or 1000 records/sec
  coming in. Bump this if the client's log volume is high.
- `retention_period = 24` (hours) — how long the stream itself holds data
  for replay, separate from the S3 retention above. This is short-term
  buffer, not long-term storage.

---

## 4. IAM role for CloudWatch Logs → Kinesis

```hcl
data "aws_iam_policy_document" "cwl_assume_role" { ... }
resource "aws_iam_role" "cwl_to_kinesis_role" { ... }
data "aws_iam_policy_document" "cwl_to_kinesis_policy" { ... }
resource "aws_iam_role_policy" "cwl_to_kinesis_policy" { ... }
```

CloudWatch Logs can't write into your Kinesis stream unless you explicitly
let it. This block:
1. Creates a role that only the CloudWatch Logs service (`logs.<region>.amazonaws.com`)
   is allowed to assume (`cwl_assume_role`)
2. Gives that role permission to do exactly two things: `kinesis:PutRecord`
   and `kinesis:PutRecords` into your specific stream — nothing else
   (`cwl_to_kinesis_policy`)

This is the AWS "least privilege" pattern — the role can only push data
into this one stream, it can't read from it, delete it, or touch anything
else.

---

## 5. The subscription filter — the actual wiring

```hcl
resource "aws_cloudwatch_log_subscription_filter" "to_kinesis" { ... }
```

This is the single resource that actually connects CloudWatch Logs to
Kinesis. It says: "on log group `var.cloudwatch_log_group_name`, take every
log event matching `var.log_filter_pattern` (empty = everything), and send
it to `aws_kinesis_stream.log_stream`, using the IAM role from step 4 to do
so."

**This is the resource that requires a log group to already exist** —
Terraform doesn't create the log group itself, since normally your
application (ECS, Lambda, EC2, etc.) already owns and creates it.

---

## 6. IAM role for Firehose → Kinesis + S3

```hcl
data "aws_iam_policy_document" "firehose_assume_role" { ... }
resource "aws_iam_role" "firehose_role" { ... }
data "aws_iam_policy_document" "firehose_policy" { ... }
resource "aws_iam_role_policy" "firehose_policy" { ... }
```

Same pattern as step 4, but for Firehose. Firehose needs to:
- **Read** from the Kinesis stream (`DescribeStream`, `GetShardIterator`,
  `GetRecords`, `ListShards`)
- **Write** to the S3 bucket (`PutObject`, `GetBucketLocation`, etc.)
- **Log its own errors** to CloudWatch Logs (so if Firehose fails to
  deliver, you can see why)

---

## 7. Firehose's own error-logging destination

```hcl
resource "aws_cloudwatch_log_group" "firehose_error_logs" { ... }
resource "aws_cloudwatch_log_stream" "firehose_error_log_stream" { ... }
```

A small, separate CloudWatch Log Group just for Firehose to report delivery
failures into (e.g. "S3 access denied", "record too large"). This is your
debugging tool if the pipeline stops working silently.

---

## 8. The Firehose delivery stream — reads Kinesis, writes S3

```hcl
resource "aws_kinesis_firehose_delivery_stream" "to_s3" { ... }
```

The actual consumer. Key settings:
- `kinesis_source_configuration` — tells Firehose which stream to read from
- `prefix` / `error_output_prefix` — how files get organized inside the S3
  bucket. Successful data lands under `raw/year=.../month=.../day=.../`;
  anything Firehose couldn't deliver lands under `errors/...` instead of
  being silently dropped
- `buffering_size` (5MB) / `buffering_interval` (300s) — Firehose batches
  records and flushes to S3 either when it hits 5MB of data or every 5
  minutes, whichever comes first. This is the real-time-vs-cost tradeoff:
  smaller/shorter = fresher data, more (smaller) S3 files; bigger/longer =
  cheaper, chunkier files
- `compression_format = "GZIP"` — files are compressed before landing in S3

---

# Usage — how to test this without real application logs

See [`end-to-end.md`](end-to-end.md) for the full operational runbook
(including a Windows/Command Prompt version of this same test). This
section is the bash/Linux version.

Since you don't have an app writing logs yet, you need to **manufacture a
fake log group and push test log lines into it manually.** Here's the
complete test flow:

### Step 1 — Create a throwaway log group to point the pipeline at

```bash
aws logs create-log-group --log-group-name /test/kinesis-pipeline
```

### Step 2 — Point your Terraform at it and deploy

In `terraform.tfvars`:
```hcl
cloudwatch_log_group_name = "/test/kinesis-pipeline"
s3_bucket_name             = "your-unique-test-bucket-name-2026"
```

For faster feedback during testing, temporarily shrink the Firehose buffer
so you don't have to wait 5 minutes for data to show up:
```hcl
firehose_buffer_size_mb          = 1
firehose_buffer_interval_seconds = 60
```

Then:
```bash
terraform init
terraform plan
terraform apply
```

### Step 3 — Push a fake log event into the log group

```bash
# create a log stream inside the log group (a log group can have many streams)
aws logs create-log-stream \
  --log-group-name /test/kinesis-pipeline \
  --log-stream-name test-stream-1

# push one test log line, timestamp in milliseconds
aws logs put-log-events \
  --log-group-name /test/kinesis-pipeline \
  --log-stream-name test-stream-1 \
  --log-events timestamp=$(date +%s000),message="hello from terraform test $(date)"
```

Run that `put-log-events` command a few times (with a new message each
time) to simulate multiple log lines.

### Step 4 — Wait, then check S3

Wait about 60–90 seconds (matching your shortened buffer interval), then:

```bash
aws s3 ls s3://your-unique-test-bucket-name-2026/raw/ --recursive
```

You should see `.gz` files appear, partitioned by date, e.g.:
```
raw/year=2026/month=07/day=06/myapp-prod-to-s3-1-2026-07-06-...gz
```

### Step 5 — Download and read the file to confirm content

```bash
aws s3 cp s3://your-unique-test-bucket-name-2026/raw/year=2026/month=07/day=06/<filename>.gz .
gunzip <filename>.gz
cat <filename>
```

You should see your test log message(s) inside, wrapped in the CloudWatch
Logs subscription-filter JSON envelope (it includes `logGroup`,
`logStream`, `logEvents`, etc. — that's normal, that's the format CloudWatch
sends over Kinesis).

### Step 6 — If nothing shows up in S3

Check, in this order:
1. **Firehose error logs** — `/aws/kinesisfirehose/<name_prefix>-to-s3` log
   group (created in step 7 above) will show exactly why delivery failed,
   if it did
2. **Subscription filter is actually attached**:
   ```bash
   aws logs describe-subscription-filters --log-group-name /test/kinesis-pipeline
   ```
3. **Data is arriving at the Kinesis stream at all** — check the
   `IncomingRecords` CloudWatch metric on the stream, or use
   `aws kinesis get-shard-iterator` + `aws kinesis get-records` to read
   directly from the shard

### Step 7 — Reset buffer settings before handing off to the client

Once you've confirmed it works end-to-end, put `firehose_buffer_size_mb`
and `firehose_buffer_interval_seconds` back to sensible production values
(5MB / 300s or higher) — the tiny test values generate far more, smaller S3
files than you'd want in production, which costs more in S3 PUT requests.

### Step 8 — Clean up test resources (optional)

```bash
aws logs delete-log-group --log-group-name /test/kinesis-pipeline
```
Then either destroy the whole test stack (`terraform destroy`) or just
repoint `cloudwatch_log_group_name` at the client's real log group and
re-apply.
