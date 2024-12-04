provider "aws" {
  region = "eu-central-1"
}

module "aws_backup" {
  source = "./.."

  plan_selection_tag = [
    {
      key   = "Environment"
      value = "dev"
    }
  ]

  rules = [
    {
      name              = "rule1"
      schedule          = "cron(0 12 * * ? *)"
      continuous_backup = true
    }
  ]
}
