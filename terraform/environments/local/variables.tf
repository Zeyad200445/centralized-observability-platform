variable "project_id" {
  description = "Project ID known to the emulator. Must match FLOCI_GCP_DEFAULT_PROJECT_ID in docker-compose.yml."
  type        = string
  default     = "obs-local"
}

variable "region" {
  description = "Region string. Not physically meaningful locally but kept identical to the cloud environment."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Default zone for zonal resources."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "obs"
}

variable "emulator_endpoint" {
  description = "Base URL of floci-gcp, with no trailing slash."
  type        = string
  default     = "http://localhost:4588"

  validation {
    condition     = can(regex("^https?://[^/]+$", var.emulator_endpoint))
    error_message = "emulator_endpoint must be a scheme + host[:port] with no trailing slash or path."
  }
}

variable "emulator_access_token" {
  description = "Static bearer token. floci-gcp does not validate credentials, but the provider demands one."
  type        = string
  default     = "floci-mock-access-token"
  sensitive   = true
}

variable "subnet_cidr" {
  description = "Primary node CIDR."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary Pod CIDR."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary Service CIDR."
  type        = string
  default     = "10.30.0.0/20"
}
