variable "project_id" {
  description = "Real GCP project ID. Required - no default on purpose."
  type        = string
}

variable "region" {
  description = "Region for the subnet and the regional cluster."
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

variable "enable_apis" {
  description = "Let Terraform enable the required Google APIs. Set false if a platform team owns that."
  type        = bool
  default     = true
}

# --- networking ------------------------------------------------------------
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

variable "master_ipv4_cidr_block" {
  description = "/28 for the private control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_source_ranges" {
  description = "Office/VPN CIDRs allowed to reach SSH and NodePorts."
  type        = list(string)
  default     = []
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the Kubernetes API server."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs. Costs money; off by default."
  type        = bool
  default     = false
}

# --- cluster ---------------------------------------------------------------
variable "kubernetes_version" {
  description = "Minimum control plane version. Empty lets the release channel decide."
  type        = string
  default     = ""
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
}

variable "machine_type" {
  description = "Node machine type. e2-standard-4 is the floor for this stack."
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Node boot disk size."
  type        = number
  default     = 100
}

variable "node_count" {
  description = "Fixed node count when autoscaling is off."
  type        = number
  default     = 3
}

variable "enable_autoscaling" {
  description = "Node pool autoscaling."
  type        = bool
  default     = true
}

variable "min_node_count" {
  description = "Autoscaler minimum. 3 keeps the ES StatefulSet spreadable."
  type        = number
  default     = 3
}

variable "max_node_count" {
  description = "Autoscaler maximum."
  type        = number
  default     = 6
}

variable "deletion_protection" {
  description = "Block terraform destroy of the cluster. Keep true in production."
  type        = bool
  default     = true
}

# --- IAM / storage ---------------------------------------------------------
variable "exporter_token_creators" {
  description = "IAM members allowed to impersonate the exporter SA, e.g. [\"user:sre@example.com\"]."
  type        = list(string)
  default     = []
}

variable "create_artifacts_bucket" {
  description = "Create a GCS bucket for Elasticsearch snapshots and dashboards."
  type        = bool
  default     = true
}

variable "artifacts_retention_days" {
  description = "Lifecycle deletion age for artifacts bucket objects."
  type        = number
  default     = 90
}

variable "labels" {
  description = "Extra labels, e.g. cost-centre and owner."
  type        = map(string)
  default     = {}
}
