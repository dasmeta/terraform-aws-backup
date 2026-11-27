mock_provider "aws" {
  alias = "source"
  mock_data "aws_sns_topic" { defaults = { arn = "arn:aws:sns:eu-central-1:111122223333:example-alerts" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:eu-central-1:111122223333:log-group:example" } }
  mock_resource "aws_cloudwatch_event_bus" { defaults = { arn = "arn:aws:events:eu-central-1:111122223333:event-bus/example" } }
}
mock_provider "aws" {
  alias = "intermediate"
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111122223333:role/example" } }
}
variables {
  name_prefix            = "example-rds"
  source_region          = "eu-central-1"
  intermediate_region    = "eu-west-1"
  account_id             = "111122223333"
  sns_topic_name         = "example-alerts"
  source_vault_arns      = ["arn:aws:backup:eu-central-1:111122223333:backup-vault:example"]
  resource_types         = ["RDS"]
  intermediate_vault_arn = "arn:aws:backup:eu-west-1:111122223333:backup-vault:intermediate"
  destination_vault_arn  = "arn:aws:backup:eu-west-1:444455556666:backup-vault:destination"
  rds_alarm_names        = ["example-forward-copy-failed", "example-rpo-age"]
}
run "routes_both_copy_stages_and_rds_alarms" {
  command = apply
  assert {
    condition     = toset(jsondecode(aws_cloudwatch_event_rule.source_failure.event_pattern).detail.state) == toset(["FAILED", "PARTIAL"]) && toset(jsondecode(aws_cloudwatch_event_rule.source_failure.event_pattern).detail.sourceBackupVaultArn) == toset(var.source_vault_arns)
    error_message = "Source copy failure events must be scoped to the configured vault."
  }
  assert {
    condition     = toset(jsondecode(aws_cloudwatch_event_rule.intermediate_failure[0].event_pattern).detail.sourceBackupVaultArn) == toset([var.intermediate_vault_arn]) && toset(jsondecode(aws_cloudwatch_event_rule.intermediate_failure[0].event_pattern).detail.destinationBackupVaultArn) == toset([var.destination_vault_arn]) && aws_cloudwatch_event_target.intermediate_failure[0].arn == aws_cloudwatch_event_bus.central[0].arn
    error_message = "The intermediate copy failures must be scoped and relayed."
  }
  assert {
    condition     = toset(jsondecode(aws_cloudwatch_event_rule.intermediate_alarm[0].event_pattern).detail.alarmName) == toset(var.rds_alarm_names) && toset(aws_cloudwatch_metric_alarm.copy_failure.alarm_actions) == toset(["arn:aws:sns:eu-central-1:111122223333:example-alerts"])
    error_message = "RDS alarm transitions must reach the configured SNS topic."
  }
}
run "source_only_has_no_intermediate_relay" {
  command = plan
  variables {
    intermediate_vault_arn = null
    destination_vault_arn  = null
    rds_alarm_names        = []
  }
  assert {
    condition     = length(aws_cloudwatch_event_bus.central) == 0 && length(aws_cloudwatch_event_rule.intermediate_failure) == 0
    error_message = "Source-only monitoring must not create a cross-region relay."
  }
}
