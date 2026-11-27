resource "aws_backup_vault" "source" {
  provider = aws.source
  name     = var.rds_copy.source_vault_name

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.source.account_id == split(":", var.rds_copy.source_role_arn)[4] && data.aws_caller_identity.intermediate.account_id == split(":", var.rds_copy.intermediate_role_arn)[4]
      error_message = "Configured AWS providers must use the same accounts as the supplied role ARNs."
    }
  }
}

resource "aws_backup_vault" "intermediate" {
  provider    = aws.intermediate
  name        = var.rds_copy.intermediate_vault_name
  kms_key_arn = aws_kms_key.intermediate.arn
}

resource "aws_backup_plan" "source" {
  provider = aws.source
  name     = local.name_prefix

  rule {
    rule_name                = local.backup_rule_name
    target_vault_name        = aws_backup_vault.source.name
    schedule                 = var.rds_copy.schedule
    enable_continuous_backup = false

    lifecycle {
      delete_after = var.rds_copy.retention_days
    }

    copy_action {
      destination_vault_arn = local.intermediate_vault_arn

      lifecycle {
        delete_after = var.rds_copy.retention_days
      }
    }
  }

  dynamic "rule" {
    for_each = var.rds_copy.archive_tiers
    content {
      rule_name                = rule.value.name
      target_vault_name        = aws_backup_vault.source.name
      schedule                 = rule.value.schedule
      enable_continuous_backup = false
      lifecycle {
        delete_after = rule.value.retention_days
      }
      copy_action {
        destination_vault_arn = local.intermediate_vault_arn
        lifecycle {
          delete_after = rule.value.retention_days
        }
      }
    }
  }

  depends_on = [aws_backup_vault.intermediate]
}

resource "aws_backup_selection" "rds" {
  provider     = aws.source
  name         = local.name_prefix
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.source.id
  resources    = [local.source_rds_arn]

  condition {
    string_equals {
      key   = "aws:ResourceTag/${local.rds_backup_tag.key}"
      value = local.rds_backup_tag.value
    }
  }

  depends_on = [aws_iam_role_policy.backup, aws_cloudwatch_event_target.copy_completed_to_intermediate]
}
