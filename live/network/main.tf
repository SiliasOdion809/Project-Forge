module "vpc" {
  source = "../../modules/vpc"

  project_name = "project-forge"
  vpc_cidr     = "10.0.0.0/16"

  public_subnets = {
    a = { cidr = "10.0.0.0/24", az = "us-east-1a" }
    b = { cidr = "10.0.1.0/24", az = "us-east-1b" }
  }

  private_subnets = {
    a = { cidr = "10.0.10.0/24", az = "us-east-1a" }
    b = { cidr = "10.0.11.0/24", az = "us-east-1b" }
  }
}