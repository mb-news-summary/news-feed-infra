# live/environments/dev/terragrunt.hcl
#
# Stack root for the dev environment.
#
# Since Terragrunt v0.67, `terragrunt run --all` requires a terragrunt.hcl
# to exist in the directory you run it from. This file satisfies that
# requirement without being a deployable unit itself.
#
# `skip = true` tells Terragrunt: "do not plan/apply this directory itself,
#  just use it as the starting point to discover child units."
#
# NO include "root" here — root.hcl calls find_in_parent_folders("env.yaml"),
# which searches *upward* from the caller's directory. Since env.yaml lives
# in this same directory (dev/), not above it, the search would fail.
# Child units (dev/project/, dev/gke-cluster/, etc.) include root.hcl
# themselves and can find env.yaml correctly because they are one level deeper.
#
# Usage:
#   cd live/environments/dev
#   terragrunt run --all plan  --non-interactive
#   terragrunt run --all apply --non-interactive --auto-approve
