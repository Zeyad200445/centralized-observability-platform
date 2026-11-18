# --- identity / placement --------------------------------------------------
variable "project_id" {
  description = "GCP project ID, or the emulator's default project locally."
  type        = string
}

variable "region" {
  description = "Region for the subnet and the regional GKE cluster."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name: local or gcp."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "gcp"], var.environment)
    error_message = "environment must be either 'local' or 'gcp'."
  }
}

variable "emulated" {
  description = "True when the Google provider points at floci-gcp."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "obs"
}

variable "labels" {
  description = "Extra labels merged onto taggable resources."
  type        = map(string)
  default     = {}
}

# --- networking ------------------------------------------------------------
variable "subnet_cidr" {
  description = "Primary CIDR for GKE nodes."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR for Pods."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR for Services."
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_ipv4_cidr_block" {
  description = "/28 for the GKE control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_source_ranges" {
  description = "Trusted CIDRs for SSH and NodePort firewall access."
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

variable "enable_private_nodes" {
  description = "Private node IPs on real GCP."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "VPC flow logs (real GCP only)."
  type        = bool
  default     = false
}

variable "enable_cloud_nat" {
  description = "Cloud NAT for private node egress (real GCP only)."
  type        = bool
  default     = true
}

# --- IAM -------------------------------------------------------------------
variable "node_sa_account_id" {
  description = "Account ID of the GKE node service account."
  type        = string
  default     = "obs-gke-node-sa"
}

variable "exporter_sa_account_id" {
  description = "Account ID of the GCP metrics exporter service account."
  type        = string
  default     = "obs-gcp-exporter-sa"
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace of the monitoring stack."
  type        = string
  default     = "monitoring"
}

variable "exporter_k8s_service_account" {
  description = "Kubernetes ServiceAccount bound to the exporter GCP SA."
  type        = string
  default     = "gcp-exporter-sa"
}

variable "exporter_can_list_resources" {
  description = "Also grant roles/browser to the exporter."
  type        = bool
  default     = false
}

variable "exporter_token_creators" {
  description = "IAM members allowed to impersonate the exporter SA."
  type        = list(string)
  default     = []
}

# --- cluster / node pool ---------------------------------------------------
variable "kubernetes_version" {
  description = "Minimum control plane version."
  type        = string
  default     = ""
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
}

variable "machine_type" {
  description = "Node machine type."
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
  description = "Autoscaler minimum."
  type        = number
  default     = 3
}

variable "max_node_count" {
  description = "Autoscaler maximum."
  type        = number
  default     = 6
}

variable "oauth_scopes" {
  description = "Node pool OAuth scopes."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "deletion_protection" {
  description = "Block terraform destroy of the cluster."
  type        = bool
  default     = false
}

variable "emulated_cluster_token" {
  description = "Static bearer token for the emulated kubeconfig."
  type        = string
  default     = "floci-mock-access-token"
  sensitive   = true
}

# --- storage ---------------------------------------------------------------
variable "create_artifacts_bucket" {
  description = "Create a GCS bucket for Elasticsearch snapshots and dashboards."
  type        = bool
  default     = false
}

variable "artifacts_retention_days" {
  description = "Lifecycle deletion age for artifacts bucket objects."
  type        = number
  default     = 90
}
