data "aws_caller_identity" "current" {}

resource "aws_kms_key" "backup" {
  description             = "${var.env}: Encrypt backup recovery points"
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.backup_kms.json
  enable_key_rotation     = true
}

resource "aws_kms_alias" "backup" {
  name          = "alias/aws_backup-${var.vault_name}"
  target_key_id = aws_kms_key.backup.arn
}

resource "aws_backup_vault" "this" {
  name        = var.vault_name
  kms_key_arn = aws_kms_key.backup.arn

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_backup_plan" "daily" {
  name = "daily-${var.env}"

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

    }
  }
}

resource "aws_backup_selection" "tagged_daily" {
  name    = "daily-tagged-${var.env}"
  plan_id = aws_backup_plan.daily.id

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
