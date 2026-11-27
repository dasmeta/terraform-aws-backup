#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'

class RdsIntermediateContractTest < Minitest::Test
  MODULE_ROOT = File.expand_path('..', __dir__)

  def test_intermediate_vault_uses_a_dedicated_customer_managed_key
    key = terraform_resource('aws_kms_key', 'intermediate')
    assert_match(/provider\s*=\s*aws\.intermediate\b/, key)

    vault = terraform_resource('aws_backup_vault', 'intermediate')
    assert_match(/kms_key_arn\s*=\s*aws_kms_key\.intermediate\.arn\b/, vault)
  end

  def test_module_leaves_cross_account_vault_access_to_the_existing_dr_vault
    refute_match(
      /^\s*resource\s+"aws_backup_vault_policy"/, terraform_source,
      'The source-account role authorizes copy-out and the existing DR vault policy authorizes copy-in'
    )
  end

  def test_backup_selection_uses_only_its_scoped_inline_policy
    selection = terraform_resource('aws_backup_selection', 'rds')
    assert_match(/iam_role_arn\s*=\s*aws_iam_role\.backup\.arn\b/, selection)
    policy = terraform_resource('aws_iam_role_policy', 'backup')
    assert_match(/^\s*role\s*=\s*aws_iam_role\.backup\.name\b/, policy)
    role = terraform_resource('aws_iam_role', 'backup')
    refute_match(/\bmanaged_policy_arns\s*=/, role)
    refute_match(/rds:ModifyDB(?:Instance|Cluster)|"ec2:|\bNot(?:Resource|Action)\s*=/i, policy)
  end

  def test_resolved_plans_detect_managed_policy_attachments_to_the_backup_role
    # Run terraform init -backend=false in the module before this mocked-plan contract.
    output, errors, status = Open3.capture3(
      'terraform', 'test', '-json', '-verbose', '-filter=tests/managed_policy_targets.tftest.hcl', chdir: MODULE_ROOT
    )
    plans = {}
    diagnostics = []
    output.each_line do |line|
      event = JSON.parse(line)
      case event['type']
      when 'test_plan'
        plans[event.fetch('@testrun')] = event.fetch('test_plan').fetch('resource_changes')
      when 'diagnostic'
        diagnostics << event.fetch('@message')
      end
    end
    assert status.success?, (diagnostics << errors).join("\n")

    unconditional = %w[aws_iam_policy_attachment.shared aws_iam_role.backup aws_iam_role_policy_attachments_exclusive.exclusive]
    assert_equal unconditional, backup_managed_policy_attachments(plans.fetch('fixture_test')).sort
    assert_equal (unconditional + ['aws_iam_role_policy_attachment.indirect[0]']).sort,
                 backup_managed_policy_attachments(plans.fetch('fixture_daily_prod')).sort

    module_plans = plans.reject { |run, _| run.start_with?('fixture_') }
    profiles = module_plans.map do |run, resources|
      selection = resources.find { |resource| resource.fetch('address') == 'aws_backup_selection.rds' }
      conditions = selection.fetch('change').fetch('after').fetch('condition')
      tags = conditions.flat_map { |condition| condition.fetch('string_equals') }
      profile = tags.find { |tag| tag.fetch('key') == 'aws:ResourceTag/backup:rule:rds' }.fetch('value')
      assert_empty backup_managed_policy_attachments(resources), "Managed policy attached to the backup role in #{run} (#{profile})"
      profile
    end
    assert_empty %w[test daily-prod] - profiles, 'Missing attachment coverage for a backup tag profile'
  end

  def test_dr_grants_only_allow_aws_resource_grant_creation
    key = terraform_resource('aws_kms_key', 'intermediate')
    refute_match(/kms:(ListGrants|RevokeGrant)/i, key)
    assert_match(/Action\s*=\s*\["kms:CreateGrant"\]\s+Resource\s*=\s*"\*"\s+Condition\s*=\s*\{ Bool = \{ "kms:GrantIsForAWSResource" = true \} \}/, key)
  end

  def test_eventbridge_matches_only_completed_rds_copies_into_the_intermediate_vault
    rule = terraform_resource('aws_cloudwatch_event_rule', 'copy_completed')
    assert_match(/^\s*provider\s*=\s*aws\.source\b/, rule)
    assert_match(/event_pattern\s*=\s*jsonencode\(/, rule)
    assert_match(/source\s*=\s*\["aws\.backup"\]/, rule)
    assert_match(/"detail-type"\s*=\s*\["Copy Job State Change"\]/, rule)
    assert_match(/state\s*=\s*\["COMPLETED"\]/, rule)
    assert_match(/resourceType\s*=\s*\["RDS"\]/, rule)
    assert_match(/destinationBackupVaultArn\s*=\s*\[local\.intermediate_vault_arn\]/, rule)
  end

  def test_eventbridge_delivers_the_source_event_to_the_intermediate_forwarder
    source_target = terraform_resource('aws_cloudwatch_event_target', 'copy_completed_to_intermediate')
    assert_match(/^\s*provider\s*=\s*aws\.source\b/, source_target)
    assert_match(/^\s*rule\s*=\s*aws_cloudwatch_event_rule\.copy_completed\.name\b/, source_target)
    assert_match(/^\s*arn\s*=\s*aws_cloudwatch_event_bus\.forwarding\.arn\b/, source_target)

    event_bus = terraform_resource('aws_cloudwatch_event_bus', 'forwarding')
    assert_match(/^\s*provider\s*=\s*aws\.intermediate\b/, event_bus)

    forwarding_rule = terraform_resource('aws_cloudwatch_event_rule', 'forward_copy')
    assert_match(/^\s*provider\s*=\s*aws\.intermediate\b/, forwarding_rule)
    assert_match(/^\s*event_bus_name\s*=\s*aws_cloudwatch_event_bus\.forwarding\.name\b/, forwarding_rule)

    forwarding_target = terraform_resource('aws_cloudwatch_event_target', 'forward_copy')
    assert_match(/^\s*provider\s*=\s*aws\.intermediate\b/, forwarding_target)
    assert_match(/^\s*event_bus_name\s*=\s*aws_cloudwatch_event_bus\.forwarding\.name\b/, forwarding_target)
    assert_match(/^\s*rule\s*=\s*aws_cloudwatch_event_rule\.forward_copy\.name\b/, forwarding_target)
    assert_match(/^\s*arn\s*=\s*aws_lambda_function\.forwarder\.arn\b/, forwarding_target)

    forwarder = terraform_resource('aws_lambda_function', 'forwarder')
    assert_match(/^\s*provider\s*=\s*aws\.intermediate\b/, forwarder)
  end

  def test_reconciliation_is_scheduled_every_fifteen_minutes
    rule = terraform_resource('aws_cloudwatch_event_rule', 'reconcile')
    assert_match(/schedule_expression\s*=\s*"rate\(15 minutes\)"/, rule)
    [rule, terraform_resource('aws_cloudwatch_event_target', 'reconcile'),
     terraform_resource('aws_lambda_permission', 'reconcile'),
     terraform_resource('aws_cloudwatch_metric_alarm', 'rpo_age'),
     terraform_resource('aws_cloudwatch_metric_alarm', 'forward_copy_failed')].each do |resource|
      assert_match(/^\s*provider\s*=\s*aws\.intermediate\b/, resource)
    end
  end

  def test_snapshot_sharing_is_the_only_rds_write_in_the_forward_copy_policy
    policy = terraform_resource('aws_iam_role_policy', 'forward_copy')
    assert_equal %w[rds:DescribeDBSnapshots rds:ListTagsForResource rds:ModifyDBSnapshotAttribute],
                 policy.scan(/"(rds:[^"]+)"/i).flatten.sort
    refute_match(/rds:ModifyDB(?:Instance|Cluster)/i, policy)
    assert_match(/Action\s*=\s*\[[^\]]*"rds:ModifyDBSnapshotAttribute"[^\]]*\]\s+Resource\s*=\s*local\.intermediate_snapshot_arn\s*$/, policy)
    arn = 'arn:${local.partition}:rds:${var.rds_copy.intermediate_region}:${local.intermediate_account_id}:snapshot:awsbackup:*'
    assert_match(/^\s*intermediate_snapshot_arn\s*=\s*"#{Regexp.escape(arn)}"\s*$/, terraform_source)
    refute_match(/"rds:/i, terraform_resource('aws_iam_role_policy', 'forwarder'))
  end

  def test_lambda_uses_the_packaged_handler_and_updates_on_code_changes
    archive = terraform_resource('archive_file', 'forwarder')
    assert_match(/source_content\s*=\s*file\("\$\{path\.module\}\/lambda\/forward_copy\.py"\)/, archive)
    assert_match(/source_content_filename\s*=\s*"forward_copy\.py"/, archive)
    forwarder = terraform_resource('aws_lambda_function', 'forwarder')
    assert_match(/filename\s*=\s*archive_file\.forwarder\.output_path\b/, forwarder)
    assert_match(/source_code_hash\s*=\s*archive_file\.forwarder\.output_base64sha256\b/, forwarder)
  end

  private

  def backup_managed_policy_attachments(resources)
    backup = resources.find { |resource| resource.fetch('address') == 'aws_iam_role.backup' }
    backup_name = backup.fetch('change').fetch('after').fetch('name')
    role_attributes = {
      'aws_iam_role_policy_attachment' => 'role',
      'aws_iam_policy_attachment' => 'roles',
      'aws_iam_role_policy_attachments_exclusive' => 'role_name'
    }
    resources.each_with_object([]) do |resource, attachments|
      address = resource.fetch('address')
      values = resource.fetch('change').fetch('after')
      unknown = resource.fetch('change').fetch('after_unknown')
      if address == 'aws_iam_role.backup'
        attachments << address unless Array(values['managed_policy_arns']).empty?
        next
      end

      target = role_attributes[resource.fetch('type')]
      next unless target

      refute_includes Array(unknown[target]), true, "#{address}.#{target} must resolve in the mocked plan"
      next unless Array(values[target]).include?(backup_name)
      next if target == 'role_name' && values['policy_arns'] == [] && !Array(unknown['policy_arns']).include?(true)

      attachments << address
    end
  end

  def terraform_source
    Dir.glob(File.join(MODULE_ROOT, '*.tf')).map { |path| File.read(path) }.join("\n")
  end

  def terraform_resource(type, name)
    declaration = "resource \"#{type}\" \"#{name}\""
    block = terraform_source[/^#{Regexp.escape(declaration)}\s*\{(.*?)^\}/m, 1]
    refute_nil block, "Expected #{declaration}"
    block
  end
end
