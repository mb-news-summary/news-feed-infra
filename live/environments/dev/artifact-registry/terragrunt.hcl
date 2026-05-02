# live/environments/dev/artifact-registry/terragrunt.hcl
#
# Docker image registry for all omnifeed services.
#
# Images are pushed by GKE-hosted GitHub Actions runners (Workload Identity,
# no credentials stored in GitHub) and pulled by GKE nodes.
# Vulnerability scanning is enabled — results visible in Cloud Console.
# Untagged images are auto-deleted to keep storage costs low.
#
# Dependency chain: project → artifact-registry (this file)

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/GoogleCloudPlatform/terraform-google-artifact-registry.git//?ref=v0.8.2"
}

dependency "project" {
  config_path = "../project"
  mock_outputs = {
    project_id     = "mock-project-id"
    project_number = "123456789012"
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
  project_id    = dependency.project.outputs.project_id
  location      = local.region
  repository_id = "${local.app}-${local.env}-docker-registry"
  format        = "DOCKER"
  description   = "Container images for the ${local.app} application (${local.env})"

  # Scan every pushed image for OS and package vulnerabilities.
  vulnerability_scanning_config = {
    enable_vulnerability_scanning = true
  }

  # IAM: the module accepts only "readers" and "writers" as keys
  # (it maps these to roles/artifactregistry.reader/writer internally).
  # GKE nodes pull images → readers.
  # CI runners push images → writers (granted via the workload-identity unit).
  members = {
    readers = [
      "serviceAccount:${dependency.project.outputs.project_number}-compute@developer.gserviceaccount.com",
    ]
  }

  labels = {
    env = local.env
    app = local.app
  }

  # Delete untagged (intermediate/dangling) images automatically.
  # Tagged images are kept — prune old tags via CI if needed.
  cleanup_policies = {
    "delete-untagged" = {
      action = "DELETE"
      condition = {
        tag_state = "UNTAGGED"
      }
    }
  }
}
