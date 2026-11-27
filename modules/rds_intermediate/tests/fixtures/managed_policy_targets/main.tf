terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "rds_copy" {
  type        = object({ rds_backup_tag_value = string })
  description = "Tag profile used to exercise conditional managed policy attachments."
}

locals {
  backup_role_name = aws_iam_role.backup.name
  policy_arn       = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role" "backup" {
  name                = "indirect-attachment-fixture"
  assume_role_policy  = jsonencode({ Version = "2012-10-17", Statement = [] })
  managed_policy_arns = [local.policy_arn]
}

resource "aws_iam_role_policy_attachment" "indirect" {
  count      = var.rds_copy.rds_backup_tag_value == "daily-prod" ? 1 : 0
  role       = local.backup_role_name
  policy_arn = local.policy_arn
}

resource "aws_iam_policy_attachment" "shared" {
  name       = "shared"
  roles      = ["other-role", local.backup_role_name]
  policy_arn = local.policy_arn
}

resource "aws_iam_role_policy_attachments_exclusive" "exclusive" {
  role_name   = local.backup_role_name
  policy_arns = [local.policy_arn]
}

resource "aws_iam_role_policy_attachment" "other" {
  role       = "other-role"
  policy_arn = local.policy_arn
}

resource "aws_iam_role_policy_attachments_exclusive" "enforce_empty" {
  role_name   = local.backup_role_name
  policy_arns = []
}
