resource "aws_backup_vault" "this" {
  name        = var.vault_name
  kms_key_arn = aws_kms_key.backup.arn

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_backup_vault_policy" "source_backup_vault_policy" {
  count = var.cross_accout_backup ? 1 : 0

  backup_vault_name = aws_backup_vault.this.name
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "AllowCrossAccountAccess",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.destination.account_id}:root"
        },
        Action = [
          "backup:CopyFromBackupVault",
          "backup:CopyIntoBackupVault"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_backup_plan" "this" {
  name = "${var.backup_plan_name}-${var.env}"

  dynamic "rule" {
    for_each = var.rules
    content {
      rule_name                = rule.value.name
      target_vault_name        = aws_backup_vault.this.name
      schedule                 = rule.value.schedule
      enable_continuous_backup = rule.value.continuous_backup

      lifecycle {
        delete_after = var.backup_retention_days
      }

      dynamic "copy_action" {
        for_each = var.cross_accout_backup ? [rule.value] : []
        content {
          destination_vault_arn = aws_backup_vault.destination_backup_vault[0].arn
          lifecycle {
            delete_after = var.backup_retention_days
          }
        }
      }
    }
  }
}

resource "aws_backup_selection" "selection_tag" {
  name    = "${var.backup_plan_name}-${var.env}-selection"
  plan_id = aws_backup_plan.this.id

  # Selection rules
  dynamic "selection_tag" {
    for_each = var.plan_selection_tag
    content {
      type  = "STRINGEQUALS"
      key   = selection_tag.value["key"]
      value = selection_tag.value["value"]
    }
  }

  iam_role_arn = aws_iam_role.backup.arn
}

resource "aws_backup_selection" "resource_selection" {
  count   = length(var.backup_selection_resources) > 0 ? 1 : 0

  name    = "${var.backup_plan_name}-${var.env}-selection"
  plan_id = aws_backup_plan.this.id

  resources = var.backup_selection_resources

  iam_role_arn = aws_iam_role.backup.arn
}
