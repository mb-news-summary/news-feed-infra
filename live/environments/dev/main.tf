# live/environments/dev/main.tf
#
# Terragrunt v0.99 calls `terraform plan` even for units marked `skip = true`,
# so this directory needs at least one valid .tf file to avoid the
# "No configuration files" error.
#
# No resources or providers are declared here — this is purely a stack root
# used as the entry point for `terragrunt run --all`. The skip = true in
# terragrunt.hcl ensures nothing in this directory is ever applied.

terraform {
  required_version = ">= 1.9"
}
