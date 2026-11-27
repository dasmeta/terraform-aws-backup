mock_provider "aws" {
  alias           = "source"
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:eu-central-1:111122223333:backup-vault:example-rds-source"
    }
  }
}

mock_provider "aws" {
  alias           = "intermediate"
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:eu-west-1:111122223333:backup-vault:example-rds-intermediate"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    }
  }
}

override_resource {
  target          = aws_iam_role.event_relay
  override_during = plan
  values          = { arn = "arn:aws:iam::111122223333:role/example-rds-source-relay" }
}

override_resource {
  target          = aws_iam_role.forward_copy
  override_during = plan
  values          = { arn = "arn:aws:iam::111122223333:role/example-rds-source-share" }
}

override_resource {
  target          = aws_iam_role.forwarder
  override_during = plan
  values          = { arn = "arn:aws:iam::111122223333:role/example-rds-source-forward" }
}

override_resource {
  target          = aws_cloudwatch_event_rule.copy_completed
  override_during = plan
  values          = { arn = "arn:aws:events:eu-central-1:111122223333:rule/example-rds-source-copy-complete" }
}

override_resource {
  target          = aws_cloudwatch_event_rule.reconcile
  override_during = plan
  values          = { arn = "arn:aws:events:eu-west-1:111122223333:rule/example-rds-source-reconcile" }
}

override_resource {
  target          = aws_cloudwatch_event_rule.forward_copy
  override_during = plan
  values          = { arn = "arn:aws:events:eu-west-1:111122223333:rule/example-rds-source-rds-copies/example-rds-source-forward" }
}

override_resource {
  target          = aws_cloudwatch_event_bus.forwarding
  override_during = plan
  values          = { arn = "arn:aws:events:eu-west-1:111122223333:event-bus/example-rds-source-rds-copies" }
}

override_resource {
  target          = aws_lambda_function.forwarder
  override_during = plan
  values          = { arn = "arn:aws:lambda:eu-west-1:111122223333:function:example-rds-source-forward" }
}

override_resource {
  target          = aws_cloudwatch_log_group.forwarder
  override_during = plan
  values          = { arn = "arn:aws:logs:eu-west-1:111122223333:log-group:/aws/lambda/example-rds-source-forward" }
}


variables {
  rds_copy = {
    source_region           = "eu-central-1"
    intermediate_region     = "eu-west-1"
    source_role_arn         = "arn:aws:iam::111122223333:role/example/source"
    intermediate_role_arn   = "arn:aws:iam::111122223333:role/example/intermediate"
    source_vault_name       = "example-rds-source"
    intermediate_vault_name = "example-rds-intermediate"
    destination_vault_arn   = "arn:aws:backup:eu-west-1:444455556666:backup-vault:example-dr"
    rds_backup_tag_value    = "daily-prod"
  }
}

run "forwards_only_completed_intermediate_rds_copies_from_the_source_rule" {
  command = plan

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.copy_completed.event_pattern) == {
      source        = ["aws.backup"]
      "detail-type" = ["Copy Job State Change"]
      account       = [local.source_account_id]
      region        = [var.rds_copy.source_region]
      detail = {
        state                     = ["COMPLETED"]
        resourceType              = ["RDS"]
        destinationBackupVaultArn = [local.intermediate_vault_arn]
      }
    } && aws_cloudwatch_event_rule.forward_copy.event_pattern == aws_cloudwatch_event_rule.copy_completed.event_pattern
    error_message = "Only the original account/Region's Backup completion for RDS and the intermediate vault may be relayed and invoked."
  }

  assert {
    condition = (
      aws_cloudwatch_event_target.copy_completed_to_intermediate.role_arn == aws_iam_role.event_relay.arn &&
      aws_cloudwatch_event_target.copy_completed_to_intermediate.arn == aws_cloudwatch_event_bus.forwarding.arn &&
      one(jsondecode(aws_iam_role.event_relay.assume_role_policy).Statement).Principal.Service == "events.amazonaws.com" &&
      one(jsondecode(aws_iam_role.event_relay.assume_role_policy).Statement).Condition.ArnEquals["aws:SourceArn"] == aws_cloudwatch_event_rule.copy_completed.arn &&
      one(jsondecode(aws_iam_role_policy.event_relay.policy).Statement).Action == "events:PutEvents" &&
      one(jsondecode(aws_iam_role_policy.event_relay.policy).Statement).Resource == aws_cloudwatch_event_bus.forwarding.arn &&
      one(jsondecode(aws_cloudwatch_event_bus_policy.forwarding.policy).Statement).Action == "events:PutEvents" &&
      one(jsondecode(aws_cloudwatch_event_bus_policy.forwarding.policy).Statement).Resource == aws_cloudwatch_event_bus.forwarding.arn &&
      one(jsondecode(aws_cloudwatch_event_bus_policy.forwarding.policy).Statement).Principal.AWS == "arn:${local.partition}:iam::${local.source_account_id}:root" &&
      one(jsondecode(aws_cloudwatch_event_bus_policy.forwarding.policy).Statement).Condition.ArnEquals["aws:SourceArn"] == aws_cloudwatch_event_rule.copy_completed.arn
    )
    error_message = "The receiving bus must grant the source account, rather than an invalid IAM role principal, permission to publish only from the sender rule."
  }

  assert {
    condition = (
      aws_cloudwatch_event_target.forward_copy.arn == aws_lambda_function.forwarder.arn &&
      aws_lambda_permission.forward_copy.function_name == aws_lambda_function.forwarder.function_name &&
      aws_lambda_permission.forward_copy.principal == "events.amazonaws.com" &&
      aws_lambda_permission.forward_copy.source_arn == aws_cloudwatch_event_rule.forward_copy.arn &&
      aws_lambda_function.forwarder.runtime == "python3.12" &&
      aws_lambda_function.forwarder.handler == "forward_copy.handler" &&
      one(aws_lambda_function.forwarder.environment).variables["INTERMEDIATE_VAULT_ARN"] == local.intermediate_vault_arn &&
      one(aws_lambda_function.forwarder.environment).variables["DESTINATION_VAULT_ARN"] == var.rds_copy.destination_vault_arn &&
      one(aws_lambda_function.forwarder.environment).variables["COPY_ROLE_ARN"] == aws_iam_role.forward_copy.arn
    )
    error_message = "The intermediate bus rule must invoke the configured Python 3.12 forwarding handler."
  }
}

run "restricts_forwarding_and_snapshot_sharing_permissions" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.forwarder.policy).Statement == [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.forwarder.arn}:log-stream:*" },
      { Effect = "Allow", Action = ["backup:StartCopyJob"], Resource = local.intermediate_snapshot_arn },
      { Effect = "Allow", Action = ["backup:ListRecoveryPointsByBackupVault"], Resource = local.intermediate_vault_arn },
      { Effect = "Allow", Action = ["backup:DescribeRecoveryPoint"], Resource = local.intermediate_snapshot_arn },
      {
        Effect    = "Allow", Action = ["backup:ListCopyJobs"], Resource = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.rds_copy.intermediate_region } }
      },
      {
        Effect    = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "Dasmeta/BackupDr", "aws:RequestedRegion" = var.rds_copy.intermediate_region } }
      },
      {
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = aws_iam_role.forward_copy.arn
        Condition = { StringEquals = { "iam:PassedToService" = "backup.amazonaws.com" } }
      },
    ]
    error_message = "Lambda must use the expected vault, snapshot, copy role, log streams, regional listing and metrics namespace."
  }

  assert {
    condition = (
      aws_lambda_function.forwarder.role == aws_iam_role.forwarder.arn &&
      aws_iam_role_policy.forwarder.role == aws_iam_role.forwarder.name &&
      aws_iam_role_policy.forward_copy.role == aws_iam_role.forward_copy.name &&
      one(jsondecode(aws_iam_role.forward_copy.assume_role_policy).Statement).Principal.Service == "backup.amazonaws.com" &&
      one(jsondecode(aws_iam_role.forwarder.assume_role_policy).Statement).Principal.Service == "lambda.amazonaws.com"
    )
    error_message = "The runtime and AWS Backup must use their own scoped roles."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.forward_copy.policy).Statement :
      statement.Effect == "Allow" && alltrue([
        for action in statement.Action : lookup({
          "backup:CopyFromBackupVault"    = local.intermediate_snapshot_arn
          "backup:CopyIntoBackupVault"    = var.rds_copy.destination_vault_arn
          "backup:DescribeBackupVault"    = local.intermediate_vault_arn
          "rds:DescribeDBSnapshots"       = local.intermediate_snapshot_arn
          "rds:ListTagsForResource"       = local.intermediate_snapshot_arn
          "rds:ModifyDBSnapshotAttribute" = local.intermediate_snapshot_arn
          "kms:DescribeKey"               = aws_kms_key.intermediate.arn
          "kms:CreateGrant"               = aws_kms_key.intermediate.arn
        }, action, "unexpected") == statement.Resource
      ])
      ]) && toset(flatten([for statement in jsondecode(aws_iam_role_policy.forward_copy.policy).Statement : statement.Action])) == toset([
      "backup:CopyFromBackupVault", "backup:CopyIntoBackupVault", "backup:DescribeBackupVault",
      "rds:ModifyDBSnapshotAttribute", "rds:DescribeDBSnapshots", "rds:ListTagsForResource", "kms:DescribeKey", "kms:CreateGrant"
    ])
    error_message = "The copy role may only share intermediate snapshots, use the intermediate key, and copy into the DR vault."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.forward_copy.policy).Statement :
      try(statement.Condition["ForAllValues:ArnEquals"]["backup:CopyTargets"], "") == var.rds_copy.destination_vault_arn &&
      try(statement.Condition.Null["backup:CopyTargets"], "") == "false" if contains(statement.Action, "backup:CopyFromBackupVault")
      ]) && alltrue([
      for statement in jsondecode(aws_iam_role_policy.forward_copy.policy).Statement :
      try(statement.Condition.Bool["kms:GrantIsForAWSResource"], false) == true if contains(statement.Action, "kms:CreateGrant")
    ])
    error_message = "Copy-out must require the DR destination, and KMS grants must be for AWS resources."
  }
}

run "reconciles_every_fifteen_minutes_and_alarms_on_failure_or_stale_copies" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_event_rule.reconcile.schedule_expression == "rate(15 minutes)" &&
      aws_cloudwatch_event_target.reconcile.rule == aws_cloudwatch_event_rule.reconcile.name &&
      aws_cloudwatch_event_target.reconcile.arn == aws_lambda_function.forwarder.arn &&
      jsondecode(aws_cloudwatch_event_target.reconcile.input) == { mode = "reconcile" } &&
      aws_lambda_permission.reconcile.principal == "events.amazonaws.com" &&
      aws_lambda_permission.reconcile.function_name == aws_lambda_function.forwarder.function_name &&
      aws_lambda_permission.reconcile.source_arn == aws_cloudwatch_event_rule.reconcile.arn &&
      aws_lambda_permission.reconcile.source_account == local.intermediate_account_id
    )
    error_message = "The intermediate schedule must invoke only the forwarder with the reconciliation payload."
  }

  assert {
    condition     = aws_lambda_function.forwarder.environment[0].variables["RETENTION_DAYS"] == tostring(var.rds_copy.retention_days)
    error_message = "The forwarder must use the configured recovery-point retention period for DR copies."
  }

  assert {
    condition = alltrue([
      for alarm in [aws_cloudwatch_metric_alarm.forward_copy_failed, aws_cloudwatch_metric_alarm.rpo_age] :
      alarm.namespace == "Dasmeta/BackupDr" && alarm.dimensions == tomap({ BackupPath = "RdsIntermediate" }) &&
      alarm.comparison_operator == "GreaterThanThreshold" && alarm.evaluation_periods == 1 && alarm.period == 900 &&
      length(alarm.alarm_actions) == 0 && length(alarm.ok_actions) == 0 && length(alarm.insufficient_data_actions) == 0
    ])
    error_message = "Both alarms must monitor the generic backup path every 15 minutes without notification actions."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.forward_copy_failed.metric_name == "ForwardCopyFailed" &&
      aws_cloudwatch_metric_alarm.forward_copy_failed.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.forward_copy_failed.threshold == 0 &&
      aws_cloudwatch_metric_alarm.forward_copy_failed.treat_missing_data == "notBreaching" &&
      aws_cloudwatch_metric_alarm.rpo_age.metric_name == "RpoAgeMinutes" &&
      aws_cloudwatch_metric_alarm.rpo_age.statistic == "Maximum" &&
      aws_cloudwatch_metric_alarm.rpo_age.threshold == 60 &&
      aws_cloudwatch_metric_alarm.rpo_age.treat_missing_data == "breaching"
    )
    error_message = "Alarm on any forwarding failure, an age over 60 minutes, or a missing RPO signal."
  }
}

run "uses_the_hourly_schedule_and_resolves_the_intermediate_vault" {
  command = plan

  assert {
    condition     = var.rds_copy.schedule == "cron(15 * ? * * *)" && var.rds_copy.retention_days == 7
    error_message = "The module must default to hourly snapshots and seven-day retention."
  }

  assert {
    condition     = local.intermediate_vault_arn == "arn:aws:backup:eu-west-1:111122223333:backup-vault:example-rds-intermediate"
    error_message = "The intermediate vault ARN must use the assumed account, intermediate Region, and vault name."
  }
}

run "rejects_out_of_range_cron_values_and_unknown_names" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { schedule = "cron(99 88 ? FOO BAR 0)" })
  }

  expect_failures = [var.rds_copy]
}

run "rejects_roles_from_different_partitions" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { intermediate_role_arn = "arn:aws-us-gov:iam::111122223333:role/example/intermediate" })
  }

  expect_failures = [var.rds_copy]
}

run "rejects_roles_from_different_accounts" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { intermediate_role_arn = "arn:aws:iam::777788889999:role/example/intermediate" })
  }

  expect_failures = [var.rds_copy]
}

run "rejects_destination_vault_in_another_region" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { destination_vault_arn = "arn:aws:backup:eu-west-2:444455556666:backup-vault:example-dr" })
  }

  expect_failures = [var.rds_copy]
}

run "rejects_destination_vault_in_the_source_account" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { destination_vault_arn = "arn:aws:backup:eu-west-1:111122223333:backup-vault:example-dr" })
  }

  expect_failures = [var.rds_copy]
}

run "rejects_retention_above_the_snapshot_limit" {
  command = plan

  variables {
    rds_copy = merge(var.rds_copy, { retention_days = 100001 })
  }

  expect_failures = [var.rds_copy]
}

run "backs_up_tagged_rds_instances_and_copies_to_ireland" {
  command = plan

  assert {
    condition     = toset(aws_backup_selection.rds.resources) == toset(["arn:aws:rds:eu-central-1:111122223333:db:*"])
    error_message = "The selection must be restricted to RDS DB instances in the source Region and account."
  }

  assert {
    condition = one(one(aws_backup_selection.rds.condition).string_equals).key == "aws:ResourceTag/backup:rule:rds" && (
      one(one(aws_backup_selection.rds.condition).string_equals).value == "daily-prod"
    )
    error_message = "The RDS selection must require the exact tag backup:rule:rds=daily-prod."
  }

  assert {
    condition     = one(aws_backup_plan.source.rule).target_vault_name == aws_backup_vault.source.name
    error_message = "The backup rule must write snapshots to the source vault."
  }

  assert {
    condition     = one(aws_backup_plan.source.rule).schedule == "cron(15 * ? * * *)"
    error_message = "The backup rule must run at 15 minutes past each hour."
  }

  assert {
    condition     = one(aws_backup_plan.source.rule).enable_continuous_backup == false
    error_message = "The RDS rule must create discrete snapshots for copying."
  }

  assert {
    condition     = one(one(aws_backup_plan.source.rule).lifecycle).delete_after == 7
    error_message = "Source recovery points must expire after seven days."
  }

  assert {
    condition     = aws_backup_vault.intermediate.name == "example-rds-intermediate" && aws_backup_vault.intermediate.arn == local.intermediate_vault_arn
    error_message = "The intermediate vault must be in Ireland in the source account."
  }

  assert {
    condition     = one(one(aws_backup_plan.source.rule).copy_action).destination_vault_arn == local.intermediate_vault_arn
    error_message = "The backup rule must copy to the intermediate vault in the source account."
  }

  assert {
    condition     = one(one(one(aws_backup_plan.source.rule).copy_action).lifecycle).delete_after == 7
    error_message = "Intermediate recovery points must expire after seven days."
  }
}

run "limits_dr_account_access_to_intermediate_key_copy_operations" {
  command = plan

  assert {
    condition     = aws_kms_key.intermediate.enable_key_rotation && aws_kms_key.intermediate.deletion_window_in_days == 7
    error_message = "The intermediate key must rotate and use a seven-day deletion window."
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(aws_kms_key.intermediate.policy).Statement : statement.Action
      if statement.Effect == "Allow" && statement.Principal.AWS == "arn:aws:iam::111122223333:root"
    ])) == toset(["kms:*"])
    error_message = "The source account must have full administration of the intermediate key."
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(aws_kms_key.intermediate.policy).Statement : statement.Action
      if statement.Effect == "Allow" && statement.Principal.AWS == "arn:aws:iam::444455556666:root"
      ])) == toset([
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom",
      "kms:CreateGrant",
    ])
    error_message = "The DR account must have only the actions required to copy and create a grant on the intermediate key."
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_kms_key.intermediate.policy).Statement :
      statement.Condition.Bool["kms:GrantIsForAWSResource"]
      if statement.Effect == "Allow" &&
      statement.Principal.AWS == "arn:aws:iam::444455556666:root" &&
      contains(statement.Action, "kms:CreateGrant")
    ]) == true
    error_message = "The DR account can create grants only through an integrated AWS service."
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_kms_key.intermediate.policy).Statement : statement.Principal.AWS
      if statement.Effect == "Allow"
    ]) == toset(["arn:aws:iam::111122223333:root", "arn:aws:iam::444455556666:root"])
    error_message = "Only the source and DR accounts may receive access in the intermediate key policy."
  }
}

run "restricts_the_backup_role_to_tagged_rds_and_the_intermediate_vault" {
  command = plan

  assert {
    condition = toset(flatten([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : statement.Action
      if statement.Effect == "Allow"
      ])) == toset([
      "backup:CopyFromBackupVault", "backup:CopyIntoBackupVault", "backup:DescribeBackupVault",
      "kms:CreateGrant", "kms:DescribeKey", "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncryptFrom", "kms:ReEncryptTo", "tag:GetResources",
      "rds:AddTagsToResource", "rds:CopyDBSnapshot", "rds:CreateDBSnapshot",
      "rds:DeleteDBSnapshot", "rds:DescribeDBInstances", "rds:DescribeDBSnapshots", "rds:ListTagsForResource",
    ])
    error_message = "The backup role must allow exactly the RDS snapshot, vault copy, tag discovery and encrypted-copy actions."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement :
      !contains(flatten([statement.Resource]), "*") || (
        toset(statement.Action) == toset(["tag:GetResources"]) &&
        try(statement.Condition.StringEquals["aws:RequestedRegion"], "") == "eu-central-1"
      ) if statement.Effect == "Allow"
    ])
    error_message = "Only source-Region tag discovery may use an unrestricted resource."
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : statement.Resource
      if statement.Effect == "Allow" && contains(statement.Action, "rds:CreateDBSnapshot")
      ])) == toset([
      "arn:aws:rds:eu-central-1:111122223333:db:*",
      "arn:aws:rds:eu-central-1:111122223333:snapshot:awsbackup:*",
    ])
    error_message = "RDS checks creation against both the source DB and the new AWS Backup snapshot."
  }

  assert {
    condition = alltrue([
      for action in ["rds:CopyDBSnapshot", "rds:DeleteDBSnapshot", "rds:AddTagsToResource"] :
      toset(flatten([
        for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : statement.Resource
        if statement.Effect == "Allow" && contains(statement.Action, action)
        ])) == toset([
        "arn:aws:rds:eu-central-1:111122223333:snapshot:awsbackup:*",
        "arn:aws:rds:eu-west-1:111122223333:snapshot:awsbackup:*",
      ])
    ])
    error_message = "Each snapshot copy, expiry and tagging permission must cover only this account's AWS Backup snapshots in the two configured Regions."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement :
      try(statement.Condition.StringEquals["aws:ResourceTag/backup:rule:rds"], "") == "daily-prod"
      if statement.Effect == "Allow" && contains(flatten([statement.Resource]), "arn:aws:rds:eu-central-1:111122223333:db:*")
    ])
    error_message = "Every grant on source instances must require the configured backup tag."
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : statement.Resource
      if statement.Effect == "Allow" && contains(statement.Action, "backup:CopyIntoBackupVault")
    ]) == toset(["arn:aws:backup:eu-west-1:111122223333:backup-vault:example-rds-intermediate"])
    error_message = "The hourly backup role may copy into the intermediate vault only."
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : {
        resource  = statement.Resource
        condition = statement.Condition
      } if statement.Effect == "Allow" && contains(statement.Action, "backup:CopyFromBackupVault")
      ]) == {
      resource = "arn:aws:rds:eu-central-1:111122223333:snapshot:awsbackup:*"
      condition = {
        "ForAllValues:ArnEquals" = { "backup:CopyTargets" = local.intermediate_vault_arn }
        Null                     = { "backup:CopyTargets" = "false" }
      }
    }
    error_message = "The backup role may copy source AWS Backup RDS snapshots only when the target is the intermediate vault."
  }
}

run "limits_encrypted_copy_permissions_to_regional_rds" {
  command = plan

  assert {
    condition = [
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : {
        actions   = toset(flatten([statement.Action]))
        resource  = statement.Resource
        condition = statement.Condition
        } if statement.Effect == "Allow" && contains(flatten([
          try(statement.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"], [])
      ]), "alias/aws/backup")
      ] == [
      {
        actions   = toset(["kms:DescribeKey"])
        resource  = "arn:aws:kms:eu-central-1:111122223333:key/*"
        condition = { "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/aws/backup" } }
      },
      {
        actions   = toset(["kms:DescribeKey"])
        resource  = "arn:aws:kms:eu-west-1:111122223333:key/*"
        condition = { "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/aws/backup" } }
      },
    ]
    error_message = "Exactly one DescribeKey statement per copy Region must be limited to that account's aws/backup key."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement :
      anytrue([
        alltrue([
          statement.Resource == aws_kms_key.intermediate.arn,
          try(statement.Condition.StringEquals["kms:ViaService"], "") == "rds.eu-west-1.amazonaws.com",
        ]),
        alltrue([
          statement.Resource == aws_kms_key.intermediate.arn,
          toset(statement.Action) == toset(["kms:DescribeKey"]),
          try(statement.Condition, null) == null,
        ]),
        alltrue([
          statement.Resource == "arn:aws:kms:eu-central-1:111122223333:key/*",
          try(statement.Condition.StringEquals["kms:ViaService"], "") == "rds.eu-central-1.amazonaws.com",
          try(statement.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"], "") == "alias/aws/rds",
        ]),
        alltrue([
          statement.Resource == "arn:aws:kms:eu-central-1:111122223333:key/*",
          toset(statement.Action) == toset(["kms:DescribeKey"]),
          try(statement.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"], "") == "alias/aws/backup",
        ]),
        alltrue([
          statement.Resource == "arn:aws:kms:eu-west-1:111122223333:key/*",
          toset(statement.Action) == toset(["kms:DescribeKey"]),
          try(statement.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"], "") == "alias/aws/backup",
        ]),
      ]) if statement.Effect == "Allow" && anytrue([for action in statement.Action : startswith(action, "kms:")])
    ])
    error_message = "Only regional RDS may use the expected copy keys. AWS Backup may also describe its managed key in each copy Region."
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : statement
      if statement.Effect == "Allow" && statement.Resource == aws_kms_key.intermediate.arn &&
      toset(statement.Action) == toset(["kms:DescribeKey"]) && try(statement.Condition, null) == null
    ]) != null
    error_message = "AWS Backup must be able to directly describe the dedicated intermediate key before it starts the copy."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement :
      try(statement.Condition.Bool["kms:GrantIsForAWSResource"], false) == true
      if statement.Effect == "Allow" && contains(statement.Action, "kms:CreateGrant")
    ])
    error_message = "Every grant must be created for an AWS resource."
  }

  assert {
    condition = alltrue([
      for service, reencrypt in {
        "rds.eu-central-1.amazonaws.com" = "kms:ReEncryptFrom"
        "rds.eu-west-1.amazonaws.com"    = "kms:ReEncryptTo"
        } : toset(flatten([
          for statement in jsondecode(aws_iam_role_policy.backup.policy).Statement : statement.Action
          if statement.Effect == "Allow" && try(statement.Condition.StringEquals["kms:ViaService"], "") == service
          ])) == toset([
          "kms:CreateGrant", "kms:DescribeKey", "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext", reencrypt,
      ])
    ])
    error_message = "Each regional RDS service requires the encrypted snapshot copy operations and the correct re-encryption direction."
  }
}

run "archive_tiers_preserve_lifecycle_in_source_and_intermediate" {
  command = plan
  variables {
    rds_copy = {
      source_region           = "eu-central-1"
      intermediate_region     = "eu-west-1"
      source_role_arn         = "arn:aws:iam::111122223333:role/example/source"
      intermediate_role_arn   = "arn:aws:iam::111122223333:role/example/intermediate"
      source_vault_name       = "example-rds-source"
      intermediate_vault_name = "example-rds-intermediate"
      destination_vault_arn   = "arn:aws:backup:eu-west-1:444455556666:backup-vault:example-dr"
      rds_backup_tag_value    = "daily-prod"
      retention_days          = 2
      archive_tiers = [
        { name = "daily", schedule = "cron(15 1 * * ? *)", retention_days = 7 },
        { name = "weekly", schedule = "cron(15 2 ? * SUN *)", retention_days = 84 },
        { name = "monthly", schedule = "cron(15 3 1 * ? *)", retention_days = 365 },
      ]
    }
  }
  assert {
    condition     = toset([for rule in aws_backup_plan.source.rule : rule.lifecycle[0].delete_after]) == toset([2, 7, 84, 365]) && alltrue([for rule in aws_backup_plan.source.rule : one(rule.copy_action).lifecycle[0].delete_after == rule.lifecycle[0].delete_after])
    error_message = "Every RDS snapshot tier must retain the same lifecycle in source and intermediate."
  }
}
