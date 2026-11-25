module "bastion" {
  source             = "../../modules/bastion"
  project_name       = "project-forge"
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_id  = data.terraform_remote_state.network.outputs.private_subnet_ids[0]
}