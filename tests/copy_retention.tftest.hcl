mock_provider "aws" {
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
}
mock_provider "aws" { alias = "destination" }

variables {
  env                      = "test"
  cross_accout_backup      = true
  backup_retention_days    = 7
  enable_sns_notifications = false
}

run "default_copy_retention_matches_source" {
  command = plan
  assert {
    condition     = one(aws_backup_plan.this.rule).lifecycle[0].delete_after == 7 && one(one(aws_backup_plan.this.rule).copy_action).lifecycle[0].delete_after == 7
    error_message = "By default the copy and source retain seven days."
  }
}

run "copy_retention_can_be_set_independently" {
  command = plan
  variables { copy_retention_days = 2 }
  assert {
    condition     = one(aws_backup_plan.this.rule).lifecycle[0].delete_after == 7 && one(one(aws_backup_plan.this.rule).copy_action).lifecycle[0].delete_after == 2
    error_message = "The source must retain seven days and the destination two."
  }
}

run "archive_tiers_have_separate_lifecycles" {
  command = plan
  variables {
    backup_selection_resources = ["arn:aws:s3:::example-backup"]
    archive_tiers = [
      { name = "weekly", schedule = "cron(0 3 ? * SUN *)", retention_days = 84 },
      { name = "monthly", schedule = "cron(0 4 1 * ? *)", retention_days = 365 },
    ]
  }
  assert {
    condition     = length(aws_backup_plan.archive) == 1 && toset([for rule in aws_backup_plan.archive[0].rule : rule.lifecycle[0].delete_after]) == toset([84, 365]) && toset([for rule in aws_backup_plan.archive[0].rule : one(rule.copy_action).lifecycle[0].delete_after]) == toset([84, 365])
    error_message = "Archive tiers must preserve their source and destination retention independently."
  }
}
