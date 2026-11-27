variable "rds_copy" {
  type = object({
    source_region           = string                                                                                           # AWS Region containing the RDS instances and source vault.
    intermediate_region     = string                                                                                           # AWS Region containing the intermediate vault in the source account.
    source_role_arn         = string                                                                                           # IAM role Terraform assumes to manage the source Region resources.
    intermediate_role_arn   = string                                                                                           # IAM role Terraform assumes to manage the intermediate Region resources.
    source_vault_name       = string                                                                                           # Name of the vault for source RDS recovery points.
    intermediate_vault_name = string                                                                                           # Name of the vault for re-encrypted intermediate copies.
    destination_vault_arn   = string                                                                                           # ARN of the existing vault in the disaster-recovery account.
    rds_backup_tag_value    = string                                                                                           # Required value of the backup:rule:rds tag on source DB instances.
    schedule                = optional(string, "cron(15 * ? * * *)")                                                           # AWS Backup cron schedule for source RDS snapshots.
    retention_days          = optional(number, 7)                                                                              # Number of days to retain RDS recovery points, from 1 to 36,500.
    copy_monitoring         = optional(object({ enabled = optional(bool, false), sns_topic_name = optional(string, "") }), {}) # Optional failure alert topic.
    archive_tiers           = optional(list(object({ name = string, schedule = string, retention_days = number })), [])        # Periodic snapshots and retention.
  })
  description = "Regions, IAM roles, vaults, and backup settings for two-stage RDS disaster-recovery copies."
  nullable    = false

  validation {
    condition = alltrue([
      for region in [var.rds_copy.source_region, var.rds_copy.intermediate_region] :
      can(regex("^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$", region))
    ])
    error_message = "source_region and intermediate_region must be AWS Region identifiers such as eu-central-1."
  }

  validation {
    condition = alltrue([
      for role_arn in [var.rds_copy.source_role_arn, var.rds_copy.intermediate_role_arn] :
      can(regex("^arn:aws(-[a-z0-9]+)*:iam::[0-9]{12}:role/([^[:space:]]+/)?[a-zA-Z0-9+=,.@_-]{1,64}$", role_arn))
    ])
    error_message = "source_role_arn and intermediate_role_arn must be IAM role ARNs."
  }

  validation {
    condition = try(
      regex("^arn:([^:]+):iam::([0-9]{12}):role/", var.rds_copy.source_role_arn) ==
      regex("^arn:([^:]+):iam::([0-9]{12}):role/", var.rds_copy.intermediate_role_arn),
      true
    )
    error_message = "source_role_arn and intermediate_role_arn must be in the same AWS partition and account."
  }

  validation {
    condition = alltrue([
      for vault_name in [var.rds_copy.source_vault_name, var.rds_copy.intermediate_vault_name] :
      can(regex("^[a-zA-Z0-9_-]{2,50}$", vault_name))
    ])
    error_message = "source_vault_name and intermediate_vault_name must contain 2 to 50 letters, digits, underscores, or hyphens."
  }

  validation {
    condition     = can(regex("^arn:aws(-[a-z0-9]+)*:backup:[a-z]{2}(-[a-z0-9]+)+-[0-9]+:[0-9]{12}:backup-vault:[a-zA-Z0-9_-]{2,50}$", var.rds_copy.destination_vault_arn))
    error_message = "destination_vault_arn must be an AWS Backup vault ARN."
  }

  validation {
    # AWS ARNs use arn:partition:service:region:account:resource.
    condition = try(
      split(":", var.rds_copy.destination_vault_arn)[1] == split(":", var.rds_copy.source_role_arn)[1] &&
      split(":", var.rds_copy.destination_vault_arn)[3] == var.rds_copy.intermediate_region &&
      split(":", var.rds_copy.destination_vault_arn)[4] != split(":", var.rds_copy.source_role_arn)[4],
      true
    )
    error_message = "destination_vault_arn must be in the source AWS partition and intermediate_region, in a different AWS account from source_role_arn."
  }

  validation {
    condition     = try(trimspace(var.rds_copy.rds_backup_tag_value) != "", false)
    error_message = "rds_backup_tag_value must contain a non-whitespace value."
  }

  validation {
    condition = one([
      for expression in regexall("^cron\\(([^()[:space:]]+([[:blank:]]+[^()[:space:]]+){5})\\)$", var.rds_copy.schedule) :
      alltrue([
        # Field order is minute, hour, day-of-month, month, day-of-week, and year.
        for index, field in [
          { value = "[0-5]?[0-9]", step = "(/[1-9][0-9]*)?", special = "" },
          { value = "[01]?[0-9]|2[0-3]", step = "(/[1-9][0-9]*)?", special = "" },
          { value = "0?[1-9]|[12][0-9]|3[01]", step = "(/[1-9][0-9]*)?", special = "|\\?|L|LW|(0?[1-9]|[12][0-9]|3[01])W" },
          { value = "0?[1-9]|1[0-2]|JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC", step = "(/[1-9][0-9]*)?", special = "" },
          { value = "0?[1-7]|SUN|MON|TUE|WED|THU|FRI|SAT", step = "", special = "|\\?|L|(0?[1-7]|SUN|MON|TUE|WED|THU|FRI|SAT)(L|#[1-5])" },
          { value = "19[7-9][0-9]|20[0-9]{2}|21[0-9]{2}", step = "(/[1-9][0-9]*)?", special = "" },
          ] : can(regex(
            "^(\\*${field.step}|(${field.value})(-(${field.value}))?${field.step}(,(${field.value})(-(${field.value}))?${field.step})*${field.special})$",
            regexall("[^[:blank:]]+", expression[0])[index]
        ))
      ]) && length(regexall("\\?", var.rds_copy.schedule)) == 1
    ]) == true
    error_message = "schedule must be a six-field AWS Backup cron expression with valid field values and ? in either day-of-month or day-of-week."
  }

  validation {
    condition = (
      var.rds_copy.retention_days >= 1 && var.rds_copy.retention_days <= 36500 &&
      floor(var.rds_copy.retention_days) == var.rds_copy.retention_days
    )
    error_message = "retention_days must be a whole number from 1 to 36,500 days."
  }
  validation {
    condition     = !var.rds_copy.copy_monitoring.enabled || can(regex("^[a-zA-Z0-9_-]{1,256}$", var.rds_copy.copy_monitoring.sns_topic_name))
    error_message = "A valid existing SNS topic name is required when copy monitoring is enabled."
  }
  validation {
    condition     = length(distinct([for tier in var.rds_copy.archive_tiers : tier.name])) == length(var.rds_copy.archive_tiers) && alltrue([for tier in var.rds_copy.archive_tiers : can(regex("^[a-zA-Z0-9-]{1,50}$", tier.name)) && tier.name != "rds-snapshot" && can(regex("^cron\\(.+\\)$", tier.schedule)) && tier.retention_days > var.rds_copy.retention_days && tier.retention_days <= 36500 && floor(tier.retention_days) == tier.retention_days])
    error_message = "Archive tiers require unique valid names, cron schedules, and whole-day retention greater than the hourly retention."
  }

}
