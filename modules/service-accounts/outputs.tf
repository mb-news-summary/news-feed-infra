output "emails" {
  description = "Map of service-account key → GSA email."
  value       = { for k, sa in google_service_account.this : k => sa.email }
}

output "names" {
  description = "Map of service-account key → GSA resource name (for IAM references)."
  value       = { for k, sa in google_service_account.this : k => sa.name }
}
