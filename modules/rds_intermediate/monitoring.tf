locals {
  metric_namespace  = "Dasmeta/BackupDr"
  metric_dimensions = { BackupPath = "RdsIntermediate" }
}

resource "aws_cloudwatch_metric_alarm" "forward_copy_failed" {
  provider            = aws.intermediate
  alarm_name          = "${local.name_prefix}-forward-copy-failed"
  alarm_description   = "The intermediate RDS forwarder observed a failed copy or reconciliation error."
  namespace           = local.metric_namespace
  metric_name         = "ForwardCopyFailed"
  dimensions          = local.metric_dimensions
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions             = []
  ok_actions                = []
  insufficient_data_actions = []
}

resource "aws_cloudwatch_metric_alarm" "rpo_age" {
  provider            = aws.intermediate
  alarm_name          = "${local.name_prefix}-rpo-age"
  alarm_description   = "The latest intermediate RDS snapshot with a completed DR copy exceeds 60 minutes, or its age is missing."
  namespace           = local.metric_namespace
  metric_name         = "RpoAgeMinutes"
  dimensions          = local.metric_dimensions
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions             = []
  ok_actions                = []
  insufficient_data_actions = []
}
