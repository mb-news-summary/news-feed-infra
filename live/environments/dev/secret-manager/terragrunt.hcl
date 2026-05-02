# live/environments/dev/secret-manager/terragrunt.hcl
#
# Creates Secret Manager secret *resources* for every sensitive credential
# the omnifeed application needs.
#
# IMPORTANT: This unit creates the secret containers only — it does NOT store
# actual secret values. Populate each secret after applying:
#
#   gcloud secrets versions add omnifeed-dev-news-api-key \
#     --project news-feed-omnifeed --data-file=- <<< "your-gnews-api-key"
#
# The External Secrets Operator (ESO) running in GKE reads these secrets via
# Workload Identity and syncs them into Kubernetes Secrets. App pods never
# touch GCP credentials directly.
#
# Dependency chain: project → secret-manager (this file)

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/GoogleCloudPlatform/terraform-google-secret-manager.git//?ref=v0.9.0"
}

dependency "project" {
  config_path = "../project"
  mock_outputs = {
    project_id = "mock-project-id"
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

  secrets = [
    # GNews API key — worker-fetcher (polling) and api-gateway (fallback direct)
    {
      name                     = "${local.app}-${local.env}-news-api-key"
      create_version           = false
      user_managed_replication = [{ location = local.region }]
    },
    # Gemini API key — worker-summarizer LLM calls
    {
      name                     = "${local.app}-${local.env}-gemini-api-key"
      create_version           = false
      user_managed_replication = [{ location = local.region }]
    },
    # PostgreSQL password — worker-summarizer and api-gateway connections
    {
      name                     = "${local.app}-${local.env}-db-password"
      create_version           = false
      user_managed_replication = [{ location = local.region }]
    },
    # RabbitMQ password — workers publish/consume
    {
      name                     = "${local.app}-${local.env}-rabbitmq-password"
      create_version           = false
      user_managed_replication = [{ location = local.region }]
    },
    # Grafana admin password — platform monitoring UI
    {
      name                     = "${local.app}-${local.env}-grafana-password"
      create_version           = false
      user_managed_replication = [{ location = local.region }]
    },
  ]

  # labels is map(map(string)): secret-name => {label-key => label-value}.
  # Omitted here — labels on secrets are optional and the flat map we had
  # doesn't match the module's expected type.
}
