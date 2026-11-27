output "source_plan_arn" {
  description = "ARN of the scheduled RDS backup plan in the source Region."
  value       = aws_backup_plan.source.arn
}

output "source_vault_arn" {
  description = "ARN of the source vault that receives RDS snapshots."
  value       = aws_backup_vault.source.arn
}

output "intermediate_vault_arn" {
  description = "ARN of the same-account vault that receives RDS copies in the intermediate Region."
  value       = aws_backup_vault.intermediate.arn
}

output "intermediate_kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts intermediate RDS copies."
  value       = aws_kms_key.intermediate.arn
}
