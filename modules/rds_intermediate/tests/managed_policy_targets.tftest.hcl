mock_provider "aws" {}

mock_provider "aws" {
  alias           = "source"
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
}

mock_provider "aws" {
  alias           = "intermediate"
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

variables {
  rds_copy = {
    source_region           = "eu-central-1"
    intermediate_region     = "eu-west-1"
    source_role_arn         = "arn:aws:iam::111122223333:role/test"
    intermediate_role_arn   = "arn:aws:iam::111122223333:role/test"
    source_vault_name       = "test-source"
    intermediate_vault_name = "test-intermediate"
    destination_vault_arn   = "arn:aws:backup:eu-west-1:444455556666:backup-vault:test-dr"
    rds_backup_tag_value    = "test"
  }
}

# The Ruby contract checks every resolved module plan and compares the two fixture controls.
run "module_test" {
  command = plan
}

run "module_daily_prod" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { rds_backup_tag_value = "daily-prod" })
  }
}

run "fixture_test" {
  command   = plan
  providers = { aws = aws.source }

  module {
    source = "./tests/fixtures/managed_policy_targets"
  }
}

run "fixture_daily_prod" {
  command   = plan
  providers = { aws = aws.source }

  variables {
    rds_copy = merge(var.rds_copy, { rds_backup_tag_value = "daily-prod" })
  }

  module {
    source = "./tests/fixtures/managed_policy_targets"
  }
}
