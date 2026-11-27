module "copy_monitor" {
  count  = var.rds_copy.copy_monitoring.enabled ? 1 : 0
  source = "../copy_monitor"
  providers = {
    aws.source       = aws.source
    aws.intermediate = aws.intermediate
  }
  name_prefix            = var.rds_copy.source_vault_name
  source_region          = var.rds_copy.source_region
  intermediate_region    = var.rds_copy.intermediate_region
  account_id             = local.source_account_id
  sns_topic_name         = var.rds_copy.copy_monitoring.sns_topic_name
  source_vault_arns      = [aws_backup_vault.source.arn]
  resource_types         = ["RDS"]
  intermediate_vault_arn = local.intermediate_vault_arn
  destination_vault_arn  = var.rds_copy.destination_vault_arn
  rds_alarm_names        = [aws_cloudwatch_metric_alarm.forward_copy_failed.alarm_name, aws_cloudwatch_metric_alarm.rpo_age.alarm_name]
}
