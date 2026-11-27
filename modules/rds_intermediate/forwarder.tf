locals {
  forwarder_name = "${local.name_prefix}-forward"
}

resource "archive_file" "forwarder" {
  type                    = "zip"
  source_content          = file("${path.module}/lambda/forward_copy.py")
  source_content_filename = "forward_copy.py"
  output_file_mode        = "0644"
  output_path             = "${path.root}/lambda-builds/${local.forwarder_name}.zip"
}

resource "aws_cloudwatch_log_group" "forwarder" {
  provider          = aws.intermediate
  name              = "/aws/lambda/${local.forwarder_name}"
  retention_in_days = 7
}

resource "aws_lambda_function" "forwarder" {
  provider         = aws.intermediate
  function_name    = local.forwarder_name
  role             = aws_iam_role.forwarder.arn
  runtime          = "python3.12"
  handler          = "forward_copy.handler"
  filename         = archive_file.forwarder.output_path
  source_code_hash = archive_file.forwarder.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      SOURCE_REGION          = var.rds_copy.source_region
      INTERMEDIATE_VAULT_ARN = local.intermediate_vault_arn
      DESTINATION_VAULT_ARN  = var.rds_copy.destination_vault_arn
      COPY_ROLE_ARN          = aws_iam_role.forward_copy.arn
      RETENTION_DAYS         = tostring(var.rds_copy.retention_days)
    }
  }

  depends_on = [aws_iam_role_policy.forwarder, aws_iam_role_policy.forward_copy]
}

resource "aws_iam_role" "forwarder" {
  provider = aws.intermediate
  name     = local.forwarder_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "forwarder" {
  provider = aws.intermediate
  name     = "start-rds-copy-job"
  role     = aws_iam_role.forwarder.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.forwarder.arn}:log-stream:*"
      },
      {
        Effect   = "Allow"
        Action   = ["backup:StartCopyJob"]
        Resource = local.intermediate_snapshot_arn
      },
      {
        Effect   = "Allow"
        Action   = ["backup:ListRecoveryPointsByBackupVault"]
        Resource = local.intermediate_vault_arn
      },
      {
        Effect   = "Allow"
        Action   = ["backup:DescribeRecoveryPoint"]
        Resource = local.intermediate_snapshot_arn
      },
      {
        Effect    = "Allow"
        Action    = ["backup:ListCopyJobs"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.rds_copy.intermediate_region } }
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = local.metric_namespace
            "aws:RequestedRegion"  = var.rds_copy.intermediate_region
          }
        }
      },
      {
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = aws_iam_role.forward_copy.arn
        Condition = { StringEquals = { "iam:PassedToService" = "backup.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_iam_role" "forward_copy" {
  provider = aws.intermediate
  name     = "${local.name_prefix}-share"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "forward_copy" {
  provider = aws.intermediate
  name     = "share-intermediate-rds-snapshots"
  role     = aws_iam_role.forward_copy.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["backup:CopyFromBackupVault"]
        Resource = local.intermediate_snapshot_arn
        Condition = {
          "ForAllValues:ArnEquals" = { "backup:CopyTargets" = var.rds_copy.destination_vault_arn }
          Null                     = { "backup:CopyTargets" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["backup:CopyIntoBackupVault"]
        Resource = var.rds_copy.destination_vault_arn
      },
      {
        Effect   = "Allow"
        Action   = ["backup:DescribeBackupVault"]
        Resource = local.intermediate_vault_arn
      },
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBSnapshots", "rds:ListTagsForResource", "rds:ModifyDBSnapshotAttribute"]
        Resource = local.intermediate_snapshot_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:DescribeKey"]
        Resource = aws_kms_key.intermediate.arn
      },
      {
        Effect    = "Allow"
        Action    = ["kms:CreateGrant"]
        Resource  = aws_kms_key.intermediate.arn
        Condition = { Bool = { "kms:GrantIsForAWSResource" = true } }
      },
    ]
  })
}
