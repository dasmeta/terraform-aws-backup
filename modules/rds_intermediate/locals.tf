data "aws_caller_identity" "source" {
  provider = aws.source
}

data "aws_caller_identity" "intermediate" {
  provider = aws.intermediate
}

data "aws_partition" "current" {
  provider = aws.intermediate
}

locals {
  name_prefix      = var.rds_copy.source_vault_name
  backup_rule_name = "rds-snapshot"
  default_tags = {
    component  = "aws_backup_rds_intermediate"
    managed_by = "terraform"
  }

  partition                 = data.aws_partition.current.partition
  source_account_id         = data.aws_caller_identity.source.account_id
  intermediate_account_id   = data.aws_caller_identity.intermediate.account_id
  intermediate_vault_arn    = "arn:${local.partition}:backup:${var.rds_copy.intermediate_region}:${local.intermediate_account_id}:backup-vault:${var.rds_copy.intermediate_vault_name}"
  source_rds_arn            = "arn:${local.partition}:rds:${var.rds_copy.source_region}:${local.source_account_id}:db:*"
  source_snapshot_arn       = "arn:${local.partition}:rds:${var.rds_copy.source_region}:${local.source_account_id}:snapshot:awsbackup:*"
  intermediate_snapshot_arn = "arn:${local.partition}:rds:${var.rds_copy.intermediate_region}:${local.intermediate_account_id}:snapshot:awsbackup:*"
  source_kms_keys_arn       = "arn:${local.partition}:kms:${var.rds_copy.source_region}:${local.source_account_id}:key/*"

  rds_backup_tag = {
    key   = "backup:rule:rds"
    value = var.rds_copy.rds_backup_tag_value
  }
}
