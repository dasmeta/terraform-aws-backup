# AWS Backup RDS intermediate copy

This module schedules snapshots of RDS DB instances in the source Region
(`eu-central-1`) and copies the recovery points through a vault in the intermediate Region
(`eu-west-1`) into the existing the intermediate Region DR account vault. Set `rds_copy.source_region` and
`rds_copy.intermediate_region` to those Regions and configure and pass `aws.source` and `aws.intermediate` provider aliases using roles in the source account. Supply the same role ARNs in `rds_copy` for input validation.

The plan selects source DB instances whose `backup:rule:rds` tag exactly
matches `rds_copy.rds_backup_tag_value`. By default, it schedules snapshots
at 15 minutes past each hour (UTC) and retains source and intermediate
recovery points for seven days.

The selection role uses `tag:GetResources` in the source Region and can create
snapshots only for tagged DB instances. RDS authorizes both the source instance
and the new snapshot. The role can tag, copy and expire AWS Backup snapshots in
the two configured Regions. Its copy-out permission requires the intermediate
vault as the sole destination.
[AWS Backup service role policy](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForBackup.html),
[RDS resource permissions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_rds.html)
and [AWS Backup copy permissions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_backup.html).

Source snapshots keep the RDS encryption key. The intermediate vault uses
a dedicated customer-managed KMS key to re-encrypt the copies. Supply
`rds_copy.destination_vault_arn` for the existing the intermediate Region DR vault so the
intermediate key policy can grant the DR account copy access.

The selection role can use the source `aws/rds` key through the source Region RDS and
the intermediate key through the intermediate Region RDS. RDS can encrypt, decrypt, generate
symmetric data keys, and create grants for AWS resources. It can re-encrypt
from the source key into the intermediate key. AWS Backup also needs
`DescribeKey` on the source Region's `aws/backup` key for cross-Region copies.
For the onward copy, the DR account can use the
intermediate key to decrypt, generate symmetric data keys, re-encrypt from
that key, and create grants through an integrated AWS service.
[AWS Backup encryption](https://docs.aws.amazon.com/aws-backup/latest/devguide/encryption.html),
[encrypted RDS snapshot copies](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CopySnapshot.html)
and [KMS re-encryption permissions](https://docs.aws.amazon.com/kms/latest/APIReference/API_ReEncrypt.html).

## Forwarding into the DR vault

AWS Backup emits the first copy job's completion event in the source Region. The rule
on the default bus matches completed RDS copies whose destination is the
configured intermediate vault. Its delivery role forwards each matching event
to the module's dedicated the intermediate Region bus. A rule on that bus invokes the the intermediate Region
Lambda, which checks the original account, Region, vault, state, resource type
and snapshot ARN before submitting a copy. The DR vault ARN comes from
`rds_copy.destination_vault_arn`. DR copies expire after seven days. Repeated
deliveries use the SHA-256 digest of the intermediate snapshot ARN as the
AWS Backup idempotency token.
[AWS cross-Region RDS backup architecture](https://aws.amazon.com/blogs/storage/protecting-encrypted-amazon-rds-instances-with-cross-account-and-cross-region-backups/),
[AWS Backup completion events](https://docs.aws.amazon.com/aws-backup/latest/devguide/eventbridge.html)
and [StartCopyJob](https://docs.aws.amazon.com/aws-backup/latest/APIReference/API_StartCopyJob.html).

Lambda passes a dedicated copy role to AWS Backup. Its only RDS write permission,
`rds:ModifyDBSnapshotAttribute`, lets AWS Backup share an intermediate snapshot
with the DR account and remove that share after the copy. The permission covers
only `snapshot:awsbackup:*` in the production account's the intermediate Region Region. The role
can copy only to the configured DR vault. Enable cross-account backup for the AWS organization
and allow `backup:CopyIntoBackupVault` from the source account in the existing
DR vault policy. The DR account's AWS Backup service-linked role copies the
shared snapshot using the DR vault's customer-managed key. The forwarding
Lambda can write its log streams, start copies of intermediate RDS snapshots,
pass the dedicated role to AWS Backup, list points in the intermediate vault,
list copy jobs in the intermediate Region and publish metrics in the `Dasmeta/BackupDr` namespace.
[AWS Backup cross-account copy permissions](https://docs.aws.amazon.com/aws-backup/latest/devguide/create-cross-account-backup.html)
and [vault access policies](https://docs.aws.amazon.com/aws-backup/latest/devguide/create-a-vault-access-policy.html).

## Reconciliation and alarms

Every 15 minutes an the intermediate Region EventBridge rule invokes the same Lambda with
`{"mode":"reconcile"}`. It pages through completed RDS recovery points in the
intermediate vault and jobs to the configured DR vault. For each original DB
instance it selects the newest point by creation time, using the snapshot ARN
to break ties. A completed or active copy needs no submission. A missing job
uses the same token as event delivery. After a terminal failed or partial job,
the worker derives a new token from the point ARN and the last failed job ID.
Concurrent retries for that attempt reuse the same token. The Lambda log
records each submitted point ARN and the returned copy job ID.
[AWS Backup recovery points](https://docs.aws.amazon.com/aws-backup/latest/APIReference/API_ListRecoveryPointsByBackupVault.html)
and [copy job filters](https://docs.aws.amazon.com/aws-backup/latest/APIReference/API_ListCopyJobs.html).

Both the intermediate Region alarms use namespace `Dasmeta/BackupDr` and dimension
`BackupPath=RdsIntermediate`. Each evaluates one 15-minute period.

| Metric | Alarm behavior |
| --- | --- |
| `ForwardCopyFailed` | Sum above zero signals a failed forwarding request, reconciliation error, or RDS job that finished as failed or partial on this path in the preceding 20 minutes. Missing data is healthy. |
| `RpoAgeMinutes` | Maximum above 60 signals that the newest intermediate snapshot with a completed DR job is over an hour old. Age is measured from snapshot creation. If no such point exists, the worker emits no age and the alarm treats missing data as breaching. |

Each run checks job completion times for failures even when a newer snapshot
already has a completed DR copy. The 20-minute window gives the 15-minute
schedule five minutes of tolerance. A failure in the overlap can appear in
two samples. A delay longer than the window can leave a gap.

The age measures the freshest confirmed snapshot across this path. Use the
resource ARN and per-point job evidence below to check a particular database.
Both alarms change state in CloudWatch. Their action lists are empty.

### Read-only evidence

Use source-account credentials in the intermediate Region. Set
`INTERMEDIATE_VAULT_NAME`, `DR_VAULT_ARN` and `SOURCE_VAULT_NAME` from
the module configuration. The first command shows each original DB, its
intermediate point and the creation time used for RPO. Match that point to the
source point of a completed DR job in the second command.

```sh
aws backup list-recovery-points-by-backup-vault --region eu-west-1 \
  --backup-vault-name "$INTERMEDIATE_VAULT_NAME" --by-resource-type RDS \
  --query "RecoveryPoints[?Status=='COMPLETED'].[ResourceArn,RecoveryPointArn,CreationDate]" --output table
aws backup list-copy-jobs --region eu-west-1 --by-destination-vault-arn "$DR_VAULT_ARN" \
  --by-resource-type RDS --by-state COMPLETED \
  --query 'CopyJobs[].[SourceRecoveryPointArn,DestinationRecoveryPointArn,CopyJobId,CompletionDate]' --output table
aws cloudwatch describe-alarms --region eu-west-1 \
  --alarm-names "${SOURCE_VAULT_NAME}-forward-copy-failed" "${SOURCE_VAULT_NAME}-rpo-age" \
  --query 'MetricAlarms[].[AlarmName,StateValue,StateReason,AlarmActions]' --output json
```

Set `START_TIME` and `END_TIME` to ISO 8601 UTC timestamps covering the
observation window to retrieve the age samples directly.

```sh
aws cloudwatch get-metric-statistics --region eu-west-1 --namespace Dasmeta/BackupDr \
  --metric-name RpoAgeMinutes --dimensions Name=BackupPath,Value=RdsIntermediate \
  --start-time "$START_TIME" --end-time "$END_TIME" --period 900 --statistics Maximum
```

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | ~> 2.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | ~> 2.7 |
| <a name="provider_aws.intermediate"></a> [aws.intermediate](#provider\_aws.intermediate) | ~> 5.0 |
| <a name="provider_aws.source"></a> [aws.source](#provider\_aws.source) | ~> 5.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [archive_file.forwarder](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/resources/file) | resource |
| [aws_backup_plan.source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.intermediate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_backup_vault.source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_cloudwatch_event_bus.forwarding](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_bus) | resource |
| [aws_cloudwatch_event_bus_policy.forwarding](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_bus_policy) | resource |
| [aws_cloudwatch_event_rule.copy_completed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.forward_copy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.copy_completed_to_intermediate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.forward_copy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.forward_copy_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rpo_age](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.event_relay](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.forward_copy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.event_relay](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.forward_copy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.intermediate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.intermediate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_lambda_function.forwarder](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.forward_copy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_caller_identity.intermediate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_caller_identity.source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_rds_copy"></a> [rds\_copy](#input\_rds\_copy) | Regions, IAM roles, vaults, and backup settings for two-stage RDS disaster-recovery copies. | <pre>object({<br>    source_region           = string                                                                                    # AWS Region containing the RDS instances and source vault.<br>    intermediate_region     = string                                                                                    # AWS Region containing the intermediate vault in the source account.<br>    source_role_arn         = string                                                                                    # IAM role Terraform assumes to manage the source Region resources.<br>    intermediate_role_arn   = string                                                                                    # IAM role Terraform assumes to manage the intermediate Region resources.<br>    source_vault_name       = string                                                                                    # Name of the vault for source RDS recovery points.<br>    intermediate_vault_name = string                                                                                    # Name of the vault for re-encrypted intermediate copies.<br>    destination_vault_arn   = string                                                                                    # ARN of the existing vault in the disaster-recovery account.<br>    rds_backup_tag_value    = string                                                                                    # Required value of the backup:rule:rds tag on source DB instances.<br>    schedule                = optional(string, "cron(15 * ? * * *)")                                                    # AWS Backup cron schedule for source RDS snapshots.<br>    retention_days          = optional(number, 7)                                                                       # Number of days to retain RDS recovery points, from 1 to 36,500.<br>    archive_tiers           = optional(list(object({ name = string, schedule = string, retention_days = number })), []) # Periodic snapshots and retention.<br>  })</pre> | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_intermediate_kms_key_arn"></a> [intermediate\_kms\_key\_arn](#output\_intermediate\_kms\_key\_arn) | ARN of the customer-managed KMS key that encrypts intermediate RDS copies. |
| <a name="output_intermediate_vault_arn"></a> [intermediate\_vault\_arn](#output\_intermediate\_vault\_arn) | ARN of the same-account vault that receives RDS copies in the intermediate Region. |
| <a name="output_source_plan_arn"></a> [source\_plan\_arn](#output\_source\_plan\_arn) | ARN of the scheduled RDS backup plan in the source Region. |
| <a name="output_source_vault_arn"></a> [source\_vault\_arn](#output\_source\_vault\_arn) | ARN of the source vault that receives RDS snapshots. |
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

## Optional archive tiers

Set `rds_copy.archive_tiers` to periodic snapshot rules with a name, AWS Backup cron schedule, and `retention_days`. The default empty list preserves existing behavior. Weekly (84-day) and monthly (365-day) tiers must be selected and scheduled deliberately. Confirm effective AWS Backup windows, source and destination lifecycles, and coordinated RDS/S3 restore behavior before production use.

The intermediate copies keep the same retention as their source rules so the forwarder can preserve it in DR. This adds intermediate storage cost. Reconciliation retries missing archive copies for seven days; failures beyond that window need operator action. Validate AWS Backup schedule overlap and the age of every resource’s newest completed DR copy before production deployment.
