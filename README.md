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

1. `terraform.tfvars` is already committed with sensible defaults for this
   module — just fill in / override:
   - `s3_bucket_name` — must be globally unique across all of AWS (not set
     in `terraform.tfvars` on purpose; pass via `TF_VAR_s3_bucket_name` or a
     CI secret, since it varies per environment)
   - `cloudwatch_log_group_name` — must already exist (this module does not
     create the log group itself, since it's usually created by whatever
     app/service is logging)
2. Set up the remote state backend (one-time per AWS account — see
   "Remote state backend setup" below) before running `terraform init`.
3. `terraform init -backend-config=backend.hcl`
4. `terraform plan`
5. `terraform apply`

## Remote state backend setup

Terraform state for this module is stored in S3 (with DynamoDB locking),
not on whatever machine happens to run `apply`. Without this, a failed or
interrupted `apply` leaves resources in AWS that a later `destroy` run has
no record of and can't clean up — state needs to persist across CI runs and
local runs alike so teardown is always reliable.

The bucket/table names are **account-specific** and deliberately *not*
hardcoded in `main.tf` — `kinesis_log/main.tf`'s `backend "s3" {}` block only
fixes the parts that don't vary (region, state key, encryption); the bucket
and DynamoDB table names are supplied at `terraform init` time. This means
the same config works unmodified in any AWS account.

**One-time bootstrap** (run once per AWS account, by an identity with
sufficient IAM rights — see `permissions/` for what the *ongoing* deploying
identity needs, which is narrower than what bootstrapping needs):
```bash
aws s3api create-bucket --bucket <STATE_BUCKET_NAME> \
  --region <REGION> --create-bucket-configuration LocationConstraint=<REGION>
aws s3api put-bucket-versioning --bucket <STATE_BUCKET_NAME> \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket <STATE_BUCKET_NAME> \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket <STATE_BUCKET_NAME> \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name <STATE_LOCK_TABLE_NAME> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region <REGION>
```

**Local use**: copy `kinesis_log/backend.hcl.example` to
`kinesis_log/backend.hcl` (gitignored — this is account-specific), fill in
the real bucket/table names, then `terraform init -backend-config=backend.hcl`.

**CI use**: set two GitHub repo secrets — `TF_STATE_BUCKET` and
`TF_STATE_DYNAMODB_TABLE` — alongside the existing `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `KINESIS_S3_BUCKET_NAME`. `kinesis-deploy.yml`
passes them to `terraform init` via `-backend-config`.

**IAM permissions**: see `permissions/terraform-deploy-policy.json` for the
full policy the deploying identity (local user or CI credentials) needs —
covers the state backend plus every resource this module creates. Fill in
the placeholders and attach it as documented in `permissions/README.md`.

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
