terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket         = "project-forge-tfstate-791316000644"
    key            = "ecr/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "project-forge-tf-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}