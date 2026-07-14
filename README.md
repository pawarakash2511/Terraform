# Terraform Examples

This repo contains three independent, self-contained Terraform examples. Each
has its own state, its own CI workflow, and its own documentation.

## [`kinesis_log/`](kinesis_log/) — CloudWatch Logs → Kinesis → Firehose → S3

A log-archiving pipeline: streams CloudWatch Logs through a Kinesis Data
Stream and Kinesis Firehose into S3. Everything lives in one `main.tf`.
Docs: **[`Kinesis_doc/`](Kinesis_doc/)** — start with
[`Kinesis_doc/getting-started.md`](Kinesis_doc/getting-started.md).

## [`Terra_example/`](Terra_example/) — example EC2 VM

A small EC2 instance with a security group (explicit inbound/outbound
rules) and an SSH key pair, demonstrating the standard multi-file Terraform
layout (`data.tf`, `variables.tf`, `outputs.tf`, `backend.tf`, `main.tf`,
`providers.tf`) and reading existing AWS resources via data sources.
Docs: **[`Terra_example_doc/`](Terra_example_doc/)** — start with
[`Terra_example_doc/README.md`](Terra_example_doc/README.md).

## [`terraform-cloudtrail-demo/`](terraform-cloudtrail-demo/) — CloudTrail → CloudWatch → SNS security alerting

Real-time AWS security event detection: wires CloudTrail into CloudWatch
Logs, adds metric filters + alarms for two scenarios (S3 bucket deletion,
root account console login), and emails alerts via SNS. Split by AWS
service area (`s3.tf`, `iam.tf`, `cloudtrail.tf`, `cloudwatch.tf`, `sns.tf`).
Docs: **[`terraform-cloudtrail-demo-docs/`](terraform-cloudtrail-demo-docs/)**
— start with
[`terraform-cloudtrail-demo-docs/README.md`](terraform-cloudtrail-demo-docs/README.md),
then [`terraform-cloudtrail-demo-docs/END_TO_END.md`](terraform-cloudtrail-demo-docs/END_TO_END.md)
for deploying/testing/tearing down.

## Shared conventions

All three examples deploy via manual GitHub Actions workflows
(`.github/workflows/`), use a remote S3+DynamoDB Terraform state backend
(same bucket, different state `key` per example — see each example's
"Remote state backend" notes), and auto-destroy on a failed apply so a bad
run never leaves a half-created stack behind. `CLAUDE.md` at the repo root
has the full technical/dev reference for all three.
