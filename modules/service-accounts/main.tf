# modules/service-accounts/main.tf
#
# Creates Google Service Accounts (GSAs), grants them IAM roles on the project,
# and establishes Workload Identity bindings so Kubernetes Service Accounts can
# impersonate them without any credentials in the cluster.

resource "google_service_account" "this" {
  for_each     = var.service_accounts
  account_id   = "${var.prefix}-${each.key}"
  display_name = lookup(each.value, "display_name", "${var.prefix}-${each.key}")
  project      = var.project_id
}

# Flatten the roles map so we can create one iam_member per (GSA, role) pair.
locals {
  role_bindings = flatten([
    for sa_key, sa in var.service_accounts : [
      for role in sa.roles : {
        sa_key = sa_key
        role   = role
      }
    ]
  ])
}

resource "google_project_iam_member" "roles" {
  for_each = {
    for b in local.role_bindings :
    "${b.sa_key}--${replace(b.role, "/", "_")}" => b
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.this[each.value.sa_key].email}"
}

# Workload Identity binding — allows a Kubernetes SA to impersonate this GSA.
# The K8s SA is identified by its namespace and name (set by Helm).
resource "google_service_account_iam_member" "workload_identity" {
  for_each = {
    for sa_key, sa in var.service_accounts : sa_key => sa
    if lookup(sa, "k8s_namespace", "") != "" && lookup(sa, "k8s_sa", "") != ""
  }
  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.k8s_namespace}/${each.value.k8s_sa}]"
}
