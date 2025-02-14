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
