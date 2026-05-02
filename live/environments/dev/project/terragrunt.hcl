# live/environments/dev/project/terragrunt.hcl
#
# Creates the GCP project that will host every resource in the dev env.
# Inherits from:
#   - live/environments/root.hcl    (provider + GCS backend)
#   - live/environments/common.yaml (org, billing, app name, region)
#   - live/environments/dev/env.yaml (folder id, environment name)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Always pin a module ref — never use HEAD.
terraform {
  source = "git::https://github.com/terraform-google-modules/terraform-google-project-factory.git//?ref=v18.2.0"
}

locals {
  common_vars = yamldecode(file("${get_parent_terragrunt_dir()}/common.yaml"))
  env_vars    = yamldecode(file(find_in_parent_folders("env.yaml")))

  # Enable APIs at project creation time so downstream units don't have to.
  # Enabling them here avoids race conditions where a module tries to use an
  # API before it's ready.
  enabled_apis = [
    "cloudresourcemanager.googleapis.com",
    "cloudbilling.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",         # GKE
    "servicenetworking.googleapis.com", # private service access (Cloud SQL / Memorystore later)
    "dns.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "artifactregistry.googleapis.com", # for image pulls
    "secretmanager.googleapis.com",
  ]
}

inputs = {
  org_id          = local.common_vars.organization_id
  folder_id       = local.env_vars.folder_id
  billing_account = local.common_vars.billing_account

  # NOTE: keeping the existing name pattern so we don't force-destroy the
  # already-applied project. For prod, you'll want a per-env suffix so the
  # two projects don't collide on project_id. See LEARNING.md.
  name = "news-feed-${local.common_vars.app_name}"

  # Best practice: do NOT create the default VPC / default firewall rules.
  # We build our own VPC in the networking unit.
  auto_create_network = false

  activate_apis = local.enabled_apis
}
