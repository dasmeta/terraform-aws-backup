data "aws_region" "monitoring_source" {
  count = var.copy_monitoring.enabled ? 1 : 0
}

module "copy_monitor" {
  count  = var.copy_monitoring.enabled ? 1 : 0
  source = "./modules/copy_monitor"
  providers = {
    aws.source       = aws
    aws.intermediate = aws.destination
  }
  name_prefix            = var.vault_name
  source_region          = data.aws_region.monitoring_source[0].name
  intermediate_region    = data.aws_region.monitoring_source[0].name
  account_id             = data.aws_caller_identity.source.account_id
  sns_topic_name         = var.copy_monitoring.sns_topic_name
  source_vault_arns      = [aws_backup_vault.this.arn]
  resource_types         = []
  intermediate_vault_arn = null
  destination_vault_arn  = null
  rds_alarm_names        = []
}
