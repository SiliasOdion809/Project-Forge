data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "project-forge-tfstate-791316000644"
    key    = "network/terraform.tfstate"
    region = "us-east-1"
  }
}
