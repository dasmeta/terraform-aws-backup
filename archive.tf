resource "aws_backup_plan" "archive" {
  count = length(var.archive_tiers) > 0 ? 1 : 0
  name  = "${var.backup_plan_name}-${var.env}-archive"

  dynamic "rule" {
    for_each = var.archive_tiers
    content {
      rule_name                = rule.value.name
      target_vault_name        = aws_backup_vault.this.name
      schedule                 = rule.value.schedule
      enable_continuous_backup = false
      lifecycle {
        delete_after = rule.value.retention_days
      }
      dynamic "copy_action" {
        for_each = var.cross_accout_backup ? [rule.value] : []
        content {
          destination_vault_arn = aws_backup_vault.destination_backup_vault[0].arn
          lifecycle {
            delete_after = copy_action.value.retention_days
          }
        }
      }
    }
  }
  lifecycle {
    precondition {
      condition     = length(var.backup_selection_resources) > 0
      error_message = "Archive tiers require explicitly selected resource ARNs."
    }
  }
}

resource "aws_backup_selection" "archive" {
  count        = length(var.archive_tiers) > 0 ? 1 : 0
  name         = "${var.backup_plan_name}-${var.env}-archive"
  plan_id      = aws_backup_plan.archive[0].id
  resources    = var.backup_selection_resources
  iam_role_arn = aws_iam_role.backup.arn
}
