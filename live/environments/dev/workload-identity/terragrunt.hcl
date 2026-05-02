# live/environments/dev/workload-identity/terragrunt.hcl
#
# Creates Google Service Accounts (GSAs) for every component that needs to call
# GCP APIs, and binds each GSA to its Kubernetes Service Account via Workload
# Identity Federation.
#
# With Workload Identity, pods get short-lived GCP credentials automatically —
# no JSON key files, no secrets rotation headaches.
#
# Components:
#   api-gateway   → Secret Manager reader (reads its own secrets)
#   worker-fetcher    → Secret Manager reader
#   worker-summarizer → Secret Manager reader
#   eso           → Secret Manager reader (External Secrets Operator)
#   gha-runner    → Artifact Registry writer (CI pushes images)
#
# Dependency chain: project → workload-identity (this file)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  # Source is our local module — one state file manages all GSAs.
  source = "${get_repo_root()}/modules/service-accounts"
}

dependency "project" {
  config_path = "../project"
  mock_outputs = {
    project_id = "mock-project-id"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "fmt"]
}

locals {
  env_vars = yamldecode(file(find_in_parent_folders("env.yaml")))
  env      = local.env_vars.environment
}

inputs = {
  project_id = dependency.project.outputs.project_id
  prefix     = "omnifeed-${local.env}"

  service_accounts = {
    # API Gateway: reads secrets from Secret Manager
    "api-gateway" = {
      display_name  = "Omnifeed API Gateway (${local.env})"
      roles         = ["roles/secretmanager.secretAccessor", "roles/cloudtrace.agent"]
      k8s_namespace = "omnifeed"
      k8s_sa        = "omnifeed-api-gateway"
    }

    # Worker Fetcher: reads secrets from Secret Manager
    "worker-fetcher" = {
      display_name  = "Omnifeed Worker Fetcher (${local.env})"
      roles         = ["roles/secretmanager.secretAccessor"]
      k8s_namespace = "omnifeed"
      k8s_sa        = "omnifeed-worker-fetcher"
    }

    # Worker Summarizer: reads secrets from Secret Manager
    "worker-summarizer" = {
      display_name  = "Omnifeed Worker Summarizer (${local.env})"
      roles         = ["roles/secretmanager.secretAccessor"]
      k8s_namespace = "omnifeed"
      k8s_sa        = "omnifeed-worker-summarizer"
    }

    # External Secrets Operator: reads all omnifeed secrets to sync into K8s
    "eso" = {
      display_name  = "External Secrets Operator (${local.env})"
      roles         = ["roles/secretmanager.secretAccessor"]
      k8s_namespace = "external-secrets"
      k8s_sa        = "external-secrets"
    }

    # GitHub Actions Runner: pushes images to Artifact Registry
    "gha-runner" = {
      display_name  = "GitHub Actions Runner (${local.env})"
      roles         = ["roles/artifactregistry.writer", "roles/storage.objectViewer"]
      k8s_namespace = "arc-runners"
      k8s_sa        = "omnifeed-runner-set"
    }
  }
}
