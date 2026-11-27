data "aws_sns_topic" "alerts" {
  provider = aws.source
  name     = var.sns_topic_name
}

locals {
  name = "${substr(var.name_prefix, 0, 35)}-${substr(md5(var.name_prefix), 0, 8)}-copy"
  source_pattern = {
    source        = ["aws.backup"]
    "detail-type" = ["Copy Job State Change"]
    account       = [var.account_id]
    region        = [var.source_region]
    detail = {
      state                = ["FAILED", "PARTIAL"]
      sourceBackupVaultArn = var.source_vault_arns
    }
  }
  intermediate_pattern = {
    source        = ["aws.backup"]
    "detail-type" = ["Copy Job State Change"]
    account       = [var.account_id]
    region        = [var.intermediate_region]
    detail = {
      state                     = ["FAILED", "PARTIAL"]
      resourceType              = var.resource_types
      sourceBackupVaultArn      = [var.intermediate_vault_arn]
      destinationBackupVaultArn = [var.destination_vault_arn]
    }
  }
  intermediate_alarm_pattern = {
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    account       = [var.account_id]
    region        = [var.intermediate_region]
    detail = {
      alarmName = var.rds_alarm_names
      state     = { value = ["ALARM"] }
    }
  }
}
resource "aws_cloudwatch_event_bus" "central" {
  count    = var.intermediate_vault_arn == null ? 0 : 1
  provider = aws.source
  name     = local.name
}
resource "aws_cloudwatch_log_group" "failures" {
  provider          = aws.source
  name              = "/aws/events/${local.name}"
  retention_in_days = 30
}
resource "aws_cloudwatch_log_resource_policy" "events" {
  provider    = aws.source
  policy_name = local.name
  policy_document = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid    = "AllowEventBridgeLogs", Effect = "Allow", Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] },
    Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.failures.arn}:*"
  }] })
}
resource "aws_cloudwatch_event_rule" "source_failure" {
  provider      = aws.source
  name          = "${local.name}-source-failures"
  event_pattern = jsonencode(local.source_pattern)
}
resource "aws_cloudwatch_event_target" "source_failure" {
  provider   = aws.source
  rule       = aws_cloudwatch_event_rule.source_failure.name
  arn        = aws_cloudwatch_log_group.failures.arn
  depends_on = [aws_cloudwatch_log_resource_policy.events]
}
resource "aws_cloudwatch_event_rule" "intermediate_failure" {
  count         = var.intermediate_vault_arn == null ? 0 : 1
  provider      = aws.intermediate
  name          = "${local.name}-rds-failures"
  event_pattern = jsonencode(local.intermediate_pattern)
}
resource "aws_cloudwatch_event_rule" "intermediate_alarm" {
  count         = var.intermediate_vault_arn == null ? 0 : 1
  provider      = aws.intermediate
  name          = "${local.name}-rds-alarms"
  event_pattern = jsonencode(local.intermediate_alarm_pattern)
}
resource "aws_iam_role" "relay" {
  count    = var.intermediate_vault_arn == null ? 0 : 1
  provider = aws.intermediate
  name     = "${local.name}-relay"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = [aws_cloudwatch_event_rule.intermediate_failure[0].arn, aws_cloudwatch_event_rule.intermediate_alarm[0].arn] } }
  }] })
}
resource "aws_iam_role_policy" "relay" {
  count    = var.intermediate_vault_arn == null ? 0 : 1
  provider = aws.intermediate
  name     = "put-central-events"
  role     = aws_iam_role.relay[0].name
  policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["events:PutEvents"], Resource = aws_cloudwatch_event_bus.central[0].arn }] })
}
resource "aws_cloudwatch_event_target" "intermediate_failure" {
  count      = var.intermediate_vault_arn == null ? 0 : 1
  provider   = aws.intermediate
  rule       = aws_cloudwatch_event_rule.intermediate_failure[0].name
  arn        = aws_cloudwatch_event_bus.central[0].arn
  role_arn   = aws_iam_role.relay[0].arn
  depends_on = [aws_iam_role_policy.relay]
}
resource "aws_cloudwatch_event_target" "intermediate_alarm" {
  count      = var.intermediate_vault_arn == null ? 0 : 1
  provider   = aws.intermediate
  rule       = aws_cloudwatch_event_rule.intermediate_alarm[0].name
  arn        = aws_cloudwatch_event_bus.central[0].arn
  role_arn   = aws_iam_role.relay[0].arn
  depends_on = [aws_iam_role_policy.relay]
}
resource "aws_cloudwatch_event_rule" "relayed_failure" {
  count          = var.intermediate_vault_arn == null ? 0 : 1
  provider       = aws.source
  name           = "${local.name}-relayed-failures"
  event_bus_name = aws_cloudwatch_event_bus.central[0].name
  event_pattern  = jsonencode({ for k, v in local.intermediate_pattern : k => v if k != "region" })
}
resource "aws_cloudwatch_event_rule" "relayed_alarm" {
  count          = var.intermediate_vault_arn == null ? 0 : 1
  provider       = aws.source
  name           = "${local.name}-relayed-alarms"
  event_bus_name = aws_cloudwatch_event_bus.central[0].name
  event_pattern  = jsonencode({ for k, v in local.intermediate_alarm_pattern : k => v if k != "region" })
}
resource "aws_cloudwatch_event_target" "relayed_failure" {
  count          = var.intermediate_vault_arn == null ? 0 : 1
  provider       = aws.source
  event_bus_name = aws_cloudwatch_event_bus.central[0].name
  rule           = aws_cloudwatch_event_rule.relayed_failure[0].name
  arn            = aws_cloudwatch_log_group.failures.arn
  depends_on     = [aws_cloudwatch_log_resource_policy.events]
}
resource "aws_cloudwatch_event_target" "relayed_alarm" {
  count          = var.intermediate_vault_arn == null ? 0 : 1
  provider       = aws.source
  event_bus_name = aws_cloudwatch_event_bus.central[0].name
  rule           = aws_cloudwatch_event_rule.relayed_alarm[0].name
  arn            = aws_cloudwatch_log_group.failures.arn
  depends_on     = [aws_cloudwatch_log_resource_policy.events]
}
resource "aws_cloudwatch_log_metric_filter" "failures" {
  provider       = aws.source
  name           = local.name
  log_group_name = aws_cloudwatch_log_group.failures.name
  pattern        = ""
  metric_transformation {
    name      = "${local.name}-events"
    namespace = "Dasmeta/BackupCopy"
    value     = "1"
  }
}
resource "aws_cloudwatch_metric_alarm" "copy_failure" {
  provider            = aws.source
  alarm_name          = "${local.name}-failure"
  alarm_description   = "Backup copy or RDS forwarding failed; inspect /aws/events/${local.name} for job details."
  namespace           = "Dasmeta/BackupCopy"
  metric_name         = "${local.name}-events"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.aws_sns_topic.alerts.arn]
}
