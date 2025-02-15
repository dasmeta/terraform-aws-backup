resource "aws_backup_vault" "destination_backup_vault" {
  count = var.cross_accout_backup ? 1 : 0

  name        = var.vault_name
  kms_key_arn = aws_kms_key.backup_vault_key[0].arn

  provider = aws.destination
}

resource "aws_backup_vault_policy" "destination_backup_vault_policy" {
  count = var.cross_accout_backup ? 1 : 0

  backup_vault_name = aws_backup_vault.destination_backup_vault[0].name
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "AllowCrossAccountAccess",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.source.account_id}:root"
        },
        Action = [
          "backup:CopyFromBackupVault",
          "backup:CopyIntoBackupVault"
        ],
        Resource = "*"
      }
    ]
  })

  provider = aws.destination

}
