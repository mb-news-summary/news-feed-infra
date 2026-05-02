variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "prefix" {
  type        = string
  description = "Name prefix for all service accounts (e.g. 'omnifeed')."
}

variable "service_accounts" {
  description = "Map of service accounts to create. Key becomes the suffix after the prefix."
  type = map(object({
    display_name  = optional(string, "")
    roles         = list(string)
    k8s_namespace = optional(string, "")
    k8s_sa        = optional(string, "")
  }))
}
