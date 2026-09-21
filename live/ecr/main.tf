module "ecr" {
  source    = "../../modules/ecr"
  repo_name = "project-forge/sample-api"
}