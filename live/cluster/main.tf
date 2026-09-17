module "eks" {
  source = "../../modules/eks"

  project_name = "project-forge"

  public_subnet_ids  = data.terraform_remote_state.network.outputs.public_subnet_ids
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
}