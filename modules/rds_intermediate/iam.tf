locals {
  rds_copy_key_actions = [
    "kms:DescribeKey",
    "kms:Decrypt",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
  ]
  source_rds_service       = "rds.${var.rds_copy.source_region}.amazonaws.com"
  intermediate_rds_service = "rds.${var.rds_copy.intermediate_region}.amazonaws.com"
}

resource "aws_iam_role" "backup" {
  provider = aws.source
  name     = "${local.name_prefix}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "backup" {
  provider = aws.source
  name     = "rds-snapshot-and-intermediate-copy"
  role     = aws_iam_role.backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DiscoverTaggedResources"
        Effect    = "Allow"
        Action    = ["tag:GetResources"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.rds_copy.source_region } }
      },
      {
        Sid      = "BackUpTaggedInstances"
        Effect   = "Allow"
        Action   = ["rds:CreateDBSnapshot", "rds:DescribeDBInstances", "rds:DescribeDBSnapshots", "rds:ListTagsForResource"]
        Resource = local.source_rds_arn
        Condition = {
          StringEquals = { "aws:ResourceTag/${local.rds_backup_tag.key}" = local.rds_backup_tag.value }
        }
      },
      {
        # RDS also checks CreateDBSnapshot against the not-yet-created snapshot.
        Sid      = "CreateSourceSnapshots"
        Effect   = "Allow"
        Action   = ["rds:CreateDBSnapshot"]
        Resource = local.source_snapshot_arn
      },
      {
        Sid    = "CopyTagAndExpireBackupSnapshots"
        Effect = "Allow"
        Action = [
          "rds:AddTagsToResource",
          "rds:CopyDBSnapshot",
          "rds:DeleteDBSnapshot",
          "rds:DescribeDBSnapshots",
          "rds:ListTagsForResource",
        ]
        Resource = [local.source_snapshot_arn, local.intermediate_snapshot_arn]
      },
      {
        Sid      = "DescribePlanVaults"
        Effect   = "Allow"
        Action   = ["backup:DescribeBackupVault"]
        Resource = [aws_backup_vault.source.arn, local.intermediate_vault_arn]
      },
      {
        Sid      = "CopySourceSnapshots"
        Effect   = "Allow"
        Action   = ["backup:CopyFromBackupVault"]
        Resource = local.source_snapshot_arn
        Condition = {
          "ForAllValues:ArnEquals" = { "backup:CopyTargets" = local.intermediate_vault_arn }
          Null                     = { "backup:CopyTargets" = "false" }
        }
      },
      {
        Sid      = "CopyIntoIntermediateVault"
        Effect   = "Allow"
        Action   = ["backup:CopyIntoBackupVault"]
        Resource = local.intermediate_vault_arn
      },
      {
        # AWS Backup checks its own managed key before starting a cross-Region copy.
        Sid      = "DescribeSourceBackupKey"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey"]
        Resource = local.source_kms_keys_arn
        Condition = {
          "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/aws/backup" }
        }
      },
      {
        # AWS Backup also preflights its regional managed key at the copy destination.
        Sid      = "DescribeIntermediateBackupKey"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey"]
        Resource = "arn:${local.partition}:kms:${var.rds_copy.intermediate_region}:${local.intermediate_account_id}:key/*"
        Condition = {
          "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/aws/backup" }
        }
      },
      {
        Sid      = "UseSourceRDSEncryptionKey"
        Effect   = "Allow"
        Action   = concat(local.rds_copy_key_actions, ["kms:ReEncryptFrom"])
        Resource = local.source_kms_keys_arn
        Condition = {
          "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/aws/rds" }
          StringEquals               = { "kms:ViaService" = local.source_rds_service }
        }
      },
      {
        Sid      = "GrantSourceRDSKey"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant"]
        Resource = local.source_kms_keys_arn
        Condition = {
          "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/aws/rds" }
          StringEquals               = { "kms:ViaService" = local.source_rds_service }
          Bool                       = { "kms:GrantIsForAWSResource" = true }
        }
      },
      {
        # AWS Backup performs this preflight outside the regional RDS service context.
        Sid      = "DescribeIntermediateEncryptionKey"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey"]
        Resource = aws_kms_key.intermediate.arn
      },
      {
        Sid       = "UseIntermediateEncryptionKey"
        Effect    = "Allow"
        Action    = concat(local.rds_copy_key_actions, ["kms:ReEncryptTo"])
        Resource  = aws_kms_key.intermediate.arn
        Condition = { StringEquals = { "kms:ViaService" = local.intermediate_rds_service } }
      },
      {
        Sid      = "GrantIntermediateKey"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant"]
        Resource = aws_kms_key.intermediate.arn
        Condition = {
          StringEquals = { "kms:ViaService" = local.intermediate_rds_service }
          Bool         = { "kms:GrantIsForAWSResource" = true }
        }
      },
    ]
  })
}
