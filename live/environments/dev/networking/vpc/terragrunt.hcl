# live/environments/dev/networking/vpc/terragrunt.hcl
#
# Creates the VPC + one regional subnet with 2 secondary ranges (pods/services)
# that GKE will consume.
#
# Reads project_id as a dependency output from ../../project so Terragrunt can
# apply these in order (project → vpc → cloud-nat → gke-cluster).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# Pin the community network module. This module is maintained by Google and
# encapsulates best practices (flow logs, private google access, etc).
terraform {
  source = "git::https://github.com/terraform-google-modules/terraform-google-network.git//?ref=v18.0.0"
}

# dependency = "read outputs from another terragrunt unit".
# When you run `terragrunt apply` in this folder it will apply ../../project
# first if it hasn't been applied yet.
dependency "project" {
  config_path = "../../project"

  # mock_outputs lets `terragrunt run-all plan` work before project is applied.
  mock_outputs = {
    project_id = "mock-project-id"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "fmt"]
}

locals {
  common_vars = yamldecode(file("${get_parent_terragrunt_dir()}/common.yaml"))
  env_vars    = yamldecode(file(find_in_parent_folders("env.yaml")))

  env    = local.env_vars.environment # "dev"
  app    = local.common_vars.app_name # "omnifeed"
  region = local.common_vars.default_region

  network_name = "${local.app}-${local.env}-vpc"
  subnet_name  = "${local.app}-${local.env}-gke-subnet"
}

inputs = {
  project_id   = dependency.project.outputs.project_id
  network_name = local.network_name

  # Turn off auto-subnets — we create our subnets explicitly with known CIDRs.
  # This is the "custom mode VPC" best practice.
  auto_create_subnetworks = false

  # Routing mode = GLOBAL means routes are shared across regions. REGIONAL is
  # slightly tighter but GLOBAL is what GKE expects for multi-region futures.
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name               = local.subnet_name
      subnet_ip                 = "10.10.0.0/20" # 4,096 IPs for node VMs
      subnet_region             = local.region
      subnet_private_access     = "true" # Private Google Access ON
      subnet_flow_logs          = "true" # VPC Flow Logs ON (cheap, useful)
      subnet_flow_logs_sampling = "0.1"  # 10% sampling keeps cost low
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
      subnet_flow_logs_interval = "INTERVAL_10_MIN"
      description               = "Subnet for GKE nodes in ${local.env}"
    }
  ]

  # Secondary ranges — GKE's "IP aliasing" / "VPC-native" mode puts pods and
  # services in these ranges instead of stealing IPs from the primary range.
  # This is the modern GKE default and what you should use in all new clusters.
  secondary_ranges = {
    (local.subnet_name) = [
      {
        range_name    = "${local.subnet_name}-pods"
        ip_cidr_range = "10.20.0.0/14" # big range — one IP per pod
      },
      {
        range_name    = "${local.subnet_name}-services"
        ip_cidr_range = "10.30.0.0/20" # one IP per ClusterIP Service
      },
    ]
  }
}
