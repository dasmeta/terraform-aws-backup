provider "aws" {
  alias   = "source"
  region  = "eu-central-1" 
}

provider "aws" {
  alias   = "destination"
  region  = "eu-central-1" 
 }


module "aws_backup" {
  source = "./../../"

  cross_accout_backup = true 

  backup_selection_resources = [
    "arn:aws:dynamodb:*:*:table/*"
  ]

  rules = [
    {
      name              = "rule1"
      schedule          = "cron(0 12 * * ? *)"
      continuous_backup = true
    }
  ]

  providers = {
    aws = aws.source
    aws.destination = aws.destination
  }

}

