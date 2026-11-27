resource "aws_cloudwatch_event_rule" "copy_completed" {
  provider = aws.source
  name     = "${local.name_prefix}-copy-complete"

  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Copy Job State Change"]
    account       = [local.source_account_id]
    region        = [var.rds_copy.source_region]
    detail = {
      state                     = ["COMPLETED"]
      resourceType              = ["RDS"]
      destinationBackupVaultArn = [local.intermediate_vault_arn]
    }
  })
}

resource "aws_cloudwatch_event_bus" "forwarding" {
  provider = aws.intermediate
  name     = "${local.name_prefix}-rds-copies"
}

resource "aws_iam_role" "event_relay" {
  provider = aws.source
  name     = "${local.name_prefix}-relay"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "events.amazonaws.com" }
      Condition = {
        ArnEquals    = { "aws:SourceArn" = aws_cloudwatch_event_rule.copy_completed.arn }
        StringEquals = { "aws:SourceAccount" = local.source_account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "event_relay" {
  provider = aws.source
  name     = "relay-to-intermediate-bus"
  role     = aws_iam_role.event_relay.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = aws_cloudwatch_event_bus.forwarding.arn
    }]
  })
}

resource "aws_cloudwatch_event_bus_policy" "forwarding" {
  provider       = aws.intermediate
  event_bus_name = aws_cloudwatch_event_bus.forwarding.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSourceCopyRule"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.source_account_id}:root" }
      Action    = "events:PutEvents"
      Resource  = aws_cloudwatch_event_bus.forwarding.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.copy_completed.arn } }
    }]
  })
}

resource "aws_cloudwatch_event_target" "copy_completed_to_intermediate" {
  provider = aws.source
  rule     = aws_cloudwatch_event_rule.copy_completed.name
  arn      = aws_cloudwatch_event_bus.forwarding.arn
  role_arn = aws_iam_role.event_relay.arn

  depends_on = [aws_iam_role_policy.event_relay, aws_cloudwatch_event_bus_policy.forwarding, aws_cloudwatch_event_target.forward_copy]
}

resource "aws_cloudwatch_event_rule" "forward_copy" {
  provider       = aws.intermediate
  name           = "${local.name_prefix}-forward"
  event_bus_name = aws_cloudwatch_event_bus.forwarding.name
  event_pattern  = aws_cloudwatch_event_rule.copy_completed.event_pattern
}

resource "aws_lambda_permission" "forward_copy" {
  provider       = aws.intermediate
  statement_id   = "ForwardCompletedRDSCopy"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.forwarder.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.forward_copy.arn
  source_account = local.source_account_id
}

resource "aws_cloudwatch_event_target" "forward_copy" {
  provider       = aws.intermediate
  event_bus_name = aws_cloudwatch_event_bus.forwarding.name
  rule           = aws_cloudwatch_event_rule.forward_copy.name
  arn            = aws_lambda_function.forwarder.arn
  depends_on     = [aws_lambda_permission.forward_copy]
}

resource "aws_cloudwatch_event_rule" "reconcile" {
  provider            = aws.intermediate
  name                = "${local.name_prefix}-reconcile"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_lambda_permission" "reconcile" {
  provider       = aws.intermediate
  statement_id   = "ReconcileRDSCopies"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.forwarder.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.reconcile.arn
  source_account = local.intermediate_account_id
}

resource "aws_cloudwatch_event_target" "reconcile" {
  provider   = aws.intermediate
  rule       = aws_cloudwatch_event_rule.reconcile.name
  arn        = aws_lambda_function.forwarder.arn
  input      = jsonencode({ mode = "reconcile" })
  depends_on = [aws_lambda_permission.reconcile]
}
