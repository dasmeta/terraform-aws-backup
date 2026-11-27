variable "vault_name" {
  description = "Backup vault name"
  type        = string
  default     = "backup_vault"
}

variable "env" {
  description = "Envrionment for the plan"
  type        = string
  default     = "prod"
}
variable "region" {
  description = "The region where resources should be managed."
  type        = string
  default     = "eu-central-1"
}

variable "backup_retention_days" {
  description = "Number of days recovery points should be kept."
  type        = number
  default     = 7
}

variable "enable_sns_notifications" {
  description = "Create an SNS topic where backup notifications go"
  type        = bool
  default     = false
}

variable "alarm_lambda_arn" {
  description = "ARN of a lambda function that should be subscribed to monitoring notifications"
  type        = string
  default     = ""
}

variable "alarm_email_addresses" {
  description = "E-Mail addresses that should be subscribed to monitoring notifications"
  type        = list(string)
  default     = []
}

variable "backup_plan_name" {
  description = "Initial part of the plan name to which will be appended the env"
  type        = string
  default     = "backup_plan"
}

variable "kms_key_alias" {
  description = "kms key alias"
  type        = string
  default     = null
}

variable "plan_selection_tag" {
  description = "Resource selection for the plan"
  type        = list(map(string))
  default = [
    {
      key   = "Environment"
      value = "Production"
    }
  ]
}

variable "rules" {
  description = "List of rules to attach to the plan"
  type        = list(any)
  default = [
    {
      name              = "daily"
      schedule          = "cron(0 12 * * ? *)"
      continuous_backup = true
      vault             = "Backup"

    }
  ]
}

variable "cross_accout_backup" {
  type        = bool
  default     = false
  description = "Enable cross account backup"
}

variable "backup_selection_resources" {
  type        = list(string)
  description = "Resources which will be backup"
  default     = []
}

variable "copy_retention_days" {
  description = "Optional retention in days for cross-account copies; defaults to source backup retention."
  type        = number
  default     = null
  validation {
    condition     = var.copy_retention_days == null ? true : var.copy_retention_days >= 1 && var.copy_retention_days <= 36500 && floor(var.copy_retention_days) == var.copy_retention_days
    error_message = "copy_retention_days must be a whole number between 1 and 36500."
  }
}

variable "archive_tiers" {
  type = list(object({
    name           = string # Unique backup rule name.
    schedule       = string # AWS Backup cron schedule.
    retention_days = number # Source and copy retention in days.
  }))
  default     = []
  description = "Optional periodic snapshot tiers for explicitly selected resources."
  validation {
    condition = alltrue([for tier in var.archive_tiers :
      can(regex("^[a-zA-Z0-9_-]{1,50}$", tier.name)) && can(regex("^cron\\(.+\\)$", tier.schedule)) && tier.retention_days >= 1 && tier.retention_days <= 36500 && floor(tier.retention_days) == tier.retention_days
    ]) && length(distinct([for tier in var.archive_tiers : tier.name])) == length(var.archive_tiers)
    error_message = "Archive tiers must have unique valid names, cron schedules and positive whole-day retention."
  }
}

variable "copy_monitoring" {
  type = object({
    enabled        = optional(bool, false) # Enable copy failure alerts.
    sns_topic_name = optional(string, "")  # Existing SNS topic in the source Region.
  })
  default     = {}
  description = "Optional copy failure monitoring using an existing SNS topic."
  validation {
    condition     = !var.copy_monitoring.enabled || can(regex("^[a-zA-Z0-9_-]{1,256}$", var.copy_monitoring.sns_topic_name))
    error_message = "A valid existing SNS topic name is required when copy monitoring is enabled."
  }
}
