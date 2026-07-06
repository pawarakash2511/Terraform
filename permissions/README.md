# IAM permissions for deploying this module

`terraform-deploy-policy.json` is the IAM policy the deploying identity
(local IAM user or the GitHub Actions credentials) needs to run
`terraform init` / `plan` / `apply` / `destroy` on `kinesis_log/` — covers
the remote state backend plus every resource the module creates. It does
**not** cover one-time backend bootstrap (`create-bucket`,
`put-bucket-versioning`, `dynamodb create-table` etc. — see the README's
"Remote state backend setup"), which typically needs a more privileged
identity to run once.

## Fill in before attaching

- `<ACCOUNT_ID>` — the target AWS account ID
- `<REGION>` — the deploy region (`ap-south-1` by default, per
  `variables.tf`)
- `<STATE_BUCKET_NAME>` / `<STATE_LOCK_TABLE_NAME>` — whatever you named the
  backend bucket/table during bootstrap
- `<NAME_PREFIX>` — matches `name_prefix` in `terraform.tfvars` (`cwlogs` by
  default); every IAM role, Kinesis stream, and Firehose delivery stream
  this module creates is named off this prefix, so the resource ARNs here
  must match it

Two statements (`S3DestinationBucket`, `CloudWatchSubscriptionFilterOnTargetLogGroup`)
are left as `Resource: "*"` since the destination bucket name and the
target CloudWatch log group name are supplied per-deploy (secret/tfvars),
not fixed — tighten those once the real values are known, if this account
hosts more than just this module.

## Attach it

```bash
aws iam put-user-policy \
  --user-name <IAM_USER_NAME> \
  --policy-name cwlogs-terraform-deploy \
  --policy-document file://terraform-deploy-policy.json
```

Run as an identity with `iam:PutUserPolicy` rights (root, or an existing
admin) — the deploying user itself typically won't have permission to grant
this to itself.
