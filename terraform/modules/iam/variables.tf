variable "project_id" {
  description = "GCP project ID owning both service accounts."
  type        = string
}

variable "node_sa_account_id" {
  description = "Account ID (local part) of the GKE node service account."
  type        = string
  default     = "obs-gke-node-sa"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.node_sa_account_id))
    error_message = "node_sa_account_id must be 6-30 chars, lowercase letters, digits and hyphens."
  }
}

variable "exporter_sa_account_id" {
  description = "Account ID (local part) of the GCP metrics exporter service account."
  type        = string
  default     = "obs-gcp-exporter-sa"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.exporter_sa_account_id))
    error_message = "exporter_sa_account_id must be 6-30 chars, lowercase letters, digits and hyphens."
  }
}

variable "exporter_k8s_namespace" {
  description = "Kubernetes namespace of the exporter's ServiceAccount."
  type        = string
  default     = "monitoring"
}

variable "exporter_k8s_service_account" {
  description = "Kubernetes ServiceAccount name bound to the exporter GCP SA."
  type        = string
  default     = "gcp-exporter-sa"
}

variable "enable_artifact_registry_pull" {
  description = "Grant roles/artifactregistry.reader to the node SA for private images."
  type        = bool
  default     = true
}

variable "exporter_can_list_resources" {
  description = "Also grant roles/browser so the exporter can enumerate project resources."
  type        = bool
  default     = false
}

variable "additional_node_sa_roles" {
  description = "Extra roles for the node SA. Keep empty unless justified."
  type        = list(string)
  default     = []
}

variable "additional_exporter_sa_roles" {
  description = "Extra roles for the exporter SA. Keep empty unless justified."
  type        = list(string)
  default     = []
}

variable "exporter_token_creators" {
  description = "IAM members allowed to impersonate the exporter SA for debugging, e.g. user:me@example.com."
  type        = list(string)
  default     = []
}
