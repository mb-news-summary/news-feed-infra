# environments/root.hcl

# 1. Dynamically load the YAML variables
locals {
  # Find the common.yaml at the root of the environments folder
  common_vars = yamldecode(file("${get_parent_terragrunt_dir()}/common.yaml"))

  # Find the env.yaml in the specific environment folder (e.g., /dev)
  env_vars = yamldecode(file("${find_in_parent_folders("env.yaml")}"))

  # Extract variables for easy use below
  project               = local.common_vars.bucket_project_id
  state_bucket_location = local.common_vars.state_bucket_location
  state_bucket_name     = local.common_vars.terragrunt_state_bucket_name
  region                = local.common_vars.default_region
  environment           = local.env_vars.environment
}

# 2. Automatically generate the Google provider for all child modules
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "google" {
  project = "${local.project}"
  region  = "${local.region}"
}
EOF
}

# 3. Automatically configure the GCS remote state bucket
remote_state {
  backend = "gcs"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket   = "${local.state_bucket_name}"
    prefix   = "${path_relative_to_include()}/terraform.tfstate"
    project  = local.project
    location = local.state_bucket_location
  }
}

# 4. Make these variables available as inputs to all child modules
inputs = merge(
  local.common_vars,
  local.env_vars
)
