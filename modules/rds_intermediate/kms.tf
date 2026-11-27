locals {
  destination_account_id = split(":", var.rds_copy.destination_vault_arn)[4]
  destination_principal  = "arn:${local.partition}:iam::${local.destination_account_id}:root"
}

resource "aws_kms_key" "intermediate" {
  provider                = aws.intermediate
  description             = "Encrypts RDS recovery points copied to ${var.rds_copy.intermediate_vault_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "SourceAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.source_account_id}:root" }
        Action    = ["kms:*"]
        Resource  = "*"
      },
      {
        Sid       = "DisasterRecoveryAccountCopy"
        Effect    = "Allow"
        Principal = { AWS = local.destination_principal }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
        ]
        Resource = "*"
      },
      {
        Sid       = "DisasterRecoveryAccountServiceGrants"
        Effect    = "Allow"
        Principal = { AWS = local.destination_principal }
        Action    = ["kms:CreateGrant"]
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
      },
    ]
  })
}

resource "aws_kms_alias" "intermediate" {
  provider      = aws.intermediate
  name          = "alias/${var.rds_copy.intermediate_vault_name}"
  target_key_id = aws_kms_key.intermediate.key_id
}
