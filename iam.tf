data "aws_iam_policy_document" "assume_backup_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "backup_permissions" {
  count = var.cross_accout_backup ? 1 : 0

  name        = "backup-permissions-policy"
  description = "Policy for AWS Backup cross-account copy"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "backup:StartCopyJob",
          "backup:GetRecoveryPointRestoreMetadata",
          "backup:CopyIntoBackupVault"
        ],
        "Resource" : "*"
      }
    ]
  })
}

resource "aws_iam_role" "backup" {
  name               = var.vault_name
  assume_role_policy = data.aws_iam_policy_document.assume_backup_role.json
}

resource "aws_iam_role_policy_attachment" "attach_backup_policy" {
  count = var.cross_accout_backup ? 1 : 0

  role       = aws_iam_role.backup.name
  policy_arn = aws_iam_policy.backup_permissions[0].arn
}

resource "aws_iam_role_policy_attachment" "service_restore_policy" {
  count = var.cross_accout_backup ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
  role       = aws_iam_role.backup.name
}

resource "aws_iam_role_policy_attachment" "main" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
  role       = aws_iam_role.backup.name
}

resource "aws_iam_role_policy_attachment" "s3_backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
}

resource "aws_iam_role_policy_attachment" "s3_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore"
}
