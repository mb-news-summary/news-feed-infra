# live/environments/dev/networking/cloud-nat/terragrunt.hcl
#
# Cloud Router + Cloud NAT for the dev VPC.
# Private GKE nodes have no public IPs; they reach the internet (image pulls,
# package updates, third-party APIs) through this NAT.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/terraform-google-modules/terraform-google-cloud-nat.git//?ref=v7.0.0"
}

# We need the project and the VPC name to attach the Router/NAT.
dependency "project" {
  config_path = "../../project"
  mock_outputs = {
    project_id = "mock-project-id"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "fmt"]
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    network_name      = "mock-network"
    network_self_link = "projects/mock/global/networks/mock-network"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "fmt"]
}

locals {
  common_vars = yamldecode(file("${get_parent_terragrunt_dir()}/common.yaml"))
  env_vars    = yamldecode(file(find_in_parent_folders("env.yaml")))

  env    = local.env_vars.environment
  app    = local.common_vars.app_name
  region = local.common_vars.default_region
}

inputs = {
  project_id = dependency.project.outputs.project_id
  region     = local.region
  name       = "${local.app}-${local.env}-nat"

  # The module will create a Cloud Router if create_router = true.
  # In prod you may want to create the router in its own unit so you can
  # attach multiple NATs or a VPN to it later.
  create_router = true
  router        = "${local.app}-${local.env}-router"
  network       = dependency.vpc.outputs.network_name

  # NAT every subnet range; simplest choice. For finer control you can set
  # source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS".
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Logging: log only errors keeps cost near zero but still shows connection
  # failures, which is what you usually want to debug.
  log_config_enable = true
  log_config_filter = "ERRORS_ONLY"
}
