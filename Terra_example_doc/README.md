# Terra Example — a small EC2 VM, the standard Terraform way

This is a second, independent Terraform example living alongside
`kinesis_log/`. Where `kinesis_log/main.tf` deliberately puts every resource
in one file, this example is split across the standard files a Terraform
module normally has — so you can see both conventions side by side.

## Why this exists

To demonstrate, in one small self-contained example, the Terraform features
that don't come up in the logging pipeline: reading existing AWS state with
`data` sources, a security group with both inbound and outbound rules
spelled out explicitly, generating a resource (an SSH key pair) from
scratch with a second provider, and the standard multi-file module layout.

## File layout and what's in each

| File | Contents |
|---|---|
| `backend.tf` | `terraform {}` block: required providers (`aws`, `tls`) + the `backend "s3" {}` block |
| `providers.tf` | `provider "aws" {}` configuration |
| `data.tf` | Reads existing AWS state — see below |
| `variables.tf` | All input variables |
| `main.tf` | The actual resources: security group, SSH key pair, the EC2 instance |
| `outputs.tf` | All outputs (last file, by convention) |

## The data source example

`data.tf` reads three things that already exist in the AWS account, instead
of creating them:
- `data "aws_vpc" "default"` — the account's default VPC (every account has
  one unless it was deliberately deleted)
- `data "aws_subnets" "default"` — existing subnets inside that VPC
- `data "aws_ami" "amazon_linux"` — the most recent Amazon Linux 2023 AMI,
  looked up by name pattern instead of a hardcoded AMI ID that goes stale

`main.tf`'s `aws_instance` then uses all three directly
(`data.aws_ami.amazon_linux.id`, `data.aws_subnets.default.ids[0]`) — this
is the "read something existing, then build with it" pattern.

## What's created, manually vs. by Terraform

**Manual, once per AWS account** (same backend this repo already uses for
`kinesis_log`):
- The state bucket + DynamoDB lock table. This example **reuses the same
  bucket and table as `kinesis_log`** — one state bucket per AWS account,
  one state file (`key`) per Terraform root, is the standard pattern. No
  new bucket needed; `backend.tf`'s `key = "terra_example/terraform.tfstate"`
  keeps this example's state completely separate from `kinesis_log`'s in
  the same bucket.
- `TF_STATE_BUCKET` / `TF_STATE_DYNAMODB_TABLE` / `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` GitHub secrets — if you've already set these up
  for `kinesis_log`, nothing new to add; `terra-example-deploy.yml` reads
  the same four.

**Created by Terraform** (`Terra_example/main.tf`):
- Security group — explicit `ingress` rules for SSH (22), HTTP (80), HTTPS
  (443) from `var.allowed_ssh_cidr` (open, `0.0.0.0/0`, by default — narrow
  this for anything beyond a quick test), and an explicit `egress` rule
  allowing all outbound traffic.
- An SSH key pair — generated entirely by Terraform (`tls_private_key` +
  `aws_key_pair`), so there's no manual key-pair setup before your first
  `apply`.
- The EC2 instance itself.

## Running it

Trigger `.github/workflows/terra-example-deploy.yml` via GitHub Actions →
**Run workflow** → `action: apply`. Same shape as the kinesis pipeline:
init (with the shared backend secrets), plan, apply, then a `terraform
output` step prints the instance ID and public IP in the Action log (the
private key stays masked as `<sensitive>` — it's never printed in CI).

## Connecting over SSH

The private key only exists in Terraform state (encrypted, in S3) — pull it
down locally once:
```bash
cd Terra_example
cp backend.hcl.example backend.hcl   # fill in the same bucket/table as kinesis_log
terraform init -backend-config=backend.hcl
terraform output -raw ssh_private_key > vm_key.pem
chmod 600 vm_key.pem   # skip on Windows; not needed there
terraform output ssh_connection_command
```
Run the printed command (or, on Windows, `ssh -i vm_key.pem ec2-user@<instance_public_ip>`)
to connect immediately — no separate manual key-pair step required at any
point.

## Destroying it

Trigger the workflow with `action: destroy` — removes the instance, key
pair, and security group. As with `kinesis_log`, **don't delete the shared
state backend (bucket/table) until this destroy succeeds** — it's shared
with `kinesis_log`'s state, and deleting it first would orphan whichever
example's resources Terraform hadn't already destroyed. There's no S3
destination bucket in this example, so the `BucketNotEmpty` gotcha from the
kinesis example doesn't apply here.
