resource "aws_kms_key" "backup" {
  description             = "${var.env}: Encrypt backup recovery points"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "AWS": [
            "arn:aws:iam::${data.aws_caller_identity.source.account_id}:root"
          ]
        },
        "Action": [
          "kms:*"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Principal": {
          "AWS": [
            "arn:aws:iam::${data.aws_caller_identity.destination.account_id}:root"
          ]
        },
        "Action": [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ],
        "Resource": "*"
      },
    ]
  })
}

resource "aws_kms_alias" "backup" {
  name          = var.kms_key_alias != null ? var.kms_key_alias : "alias/aws_backup-${var.vault_name}-${var.env}"
  target_key_id = aws_kms_key.backup.arn
}


