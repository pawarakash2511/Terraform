# Terraform Examples

This repo contains two independent, self-contained Terraform examples. Each
has its own state, its own CI workflow, and its own documentation folder.

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

## Shared conventions

Both examples deploy via manual GitHub Actions workflows
(`.github/workflows/`), use a remote S3+DynamoDB Terraform state backend
(same bucket, different state `key` per example — see either doc folder's
"Remote state backend" notes), and auto-destroy on a failed apply so a bad
run never leaves a half-created stack behind. `CLAUDE.md` at the repo root
has the full technical/dev reference for both.
