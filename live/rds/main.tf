module "rds" {
  source = "../../modules/rds"

  project_name        = "project-forge"
  vpc_id              = data.terraform_remote_state.network.outputs.vpc_id
  vpc_cidr            = "10.0.0.0/16"
  private_subnet_ids  = data.terraform_remote_state.network.outputs.private_subnet_ids
}