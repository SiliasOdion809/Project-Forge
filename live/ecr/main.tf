module "ecr" {
  source    = "../../modules/ecr"
  repo_name = "project-forge/sample-api"
}

module "ecr_greeting_service" {
  source    = "../../modules/ecr"
  repo_name = "project-forge/greeting-service"
}