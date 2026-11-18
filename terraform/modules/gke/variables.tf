variable "project_id" {
  description = "GCP project ID hosting the cluster."
  type        = string
}

variable "location" {
  description = "Region (regional cluster) or zone (zonal cluster)."
  type        = string
}

variable "environment" {
  description = "Environment label: local or gcp."
  type        = string
  default     = "local"
}

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "obs-gke"
}

variable "emulated" {
  description = "True when targeting floci-gcp. Disables GKE features k3s cannot model."
  type        = bool
  default     = false
}

# --- networking ------------------------------------------------------------
variable "network" {
  description = "VPC network ID from modules/vpc."
  type        = string
}

variable "subnetwork" {
  description = "Subnetwork ID from modules/vpc."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for Pod IPs."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for Service ClusterIPs."
  type        = string
}

variable "node_network_tag" {
  description = "Network tag applied to nodes so the VPC firewall rules match."
  type        = string
  default     = "obs-gke-node"
}

variable "enable_private_nodes" {
  description = "Give nodes internal IPs only."
  type        = bool
  default     = true
}

variable "enable_private_endpoint" {
  description = "Make the control plane endpoint private. Keep false so CI can reach it."
  type        = bool
  default     = false
}

variable "master_ipv4_cidr_block" {
  description = "/28 reserved for the GKE control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the Kubernetes API server."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# --- versions / channel ----------------------------------------------------
variable "kubernetes_version" {
  description = "Minimum control plane version. Empty string lets GKE choose."
  type        = string
  default     = ""
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR, STABLE or UNSPECIFIED."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "UNSPECIFIED"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR, STABLE or UNSPECIFIED."
  }
}

# --- node pool -------------------------------------------------------------
variable "node_pool_name" {
  description = "Name of the managed node pool."
  type        = string
  default     = "obs-node-pool"
}

variable "node_service_account_email" {
  description = "Email of the node service account from modules/iam."
  type        = string
}

variable "machine_type" {
  description = "Node machine type. e2-standard-4 fits ES + Prometheus + Grafana."
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Boot disk size per node in GB."
  type        = number
  default     = 100
}

variable "disk_type" {
  description = "Boot disk type."
  type        = string
  default     = "pd-balanced"
}

variable "image_type" {
  description = "Node image type."
  type        = string
  default     = "COS_CONTAINERD"
}

variable "node_count" {
  description = "Fixed node count when autoscaling is disabled."
  type        = number
  default     = 3
}

variable "enable_autoscaling" {
  description = "Enable node pool autoscaling."
  type        = bool
  default     = true
}

variable "min_node_count" {
  description = "Minimum nodes when autoscaling."
  type        = number
  default     = 3
}

variable "max_node_count" {
  description = "Maximum nodes when autoscaling."
  type        = number
  default     = 6
}

variable "preemptible" {
  description = "Use preemptible VMs. Never for stateful Elasticsearch."
  type        = bool
  default     = false
}

variable "spot" {
  description = "Use Spot VMs."
  type        = bool
  default     = false
}

variable "oauth_scopes" {
  description = "OAuth scopes on the node pool. cloud-platform + IAM roles is the GKE-recommended pattern."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "node_labels" {
  description = "Extra Kubernetes node labels."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Node taints applied to the pool."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "enable_sysctl_tuning" {
  description = "Apply sysctl tuning suited to Elasticsearch and Logstash."
  type        = bool
  default     = true
}

# --- addons / policy -------------------------------------------------------
variable "enable_http_load_balancing" {
  description = "Enable the GCLB ingress addon (needed to expose Kibana/Grafana)."
  type        = bool
  default     = true
}

variable "enable_hpa" {
  description = "Enable horizontal pod autoscaling addon."
  type        = bool
  default     = true
}

variable "enable_filestore_csi" {
  description = "Enable the Filestore CSI driver for RWX volumes."
  type        = bool
  default     = false
}

variable "gke_system_logging_components" {
  description = "GKE system log components. SYSTEM_COMPONENTS only: workload logs go to our ELK stack."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS"]
}

variable "gke_system_monitoring_components" {
  description = "GKE system metric components. Managed Prometheus stays off; we run our own."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS"]
}

variable "maintenance_start_time" {
  description = "RFC3339 start of the maintenance window."
  type        = string
  default     = "2026-01-01T02:00:00Z"
}

variable "maintenance_end_time" {
  description = "RFC3339 end of the maintenance window."
  type        = string
  default     = "2026-01-01T06:00:00Z"
}

variable "maintenance_recurrence" {
  description = "RRULE for the maintenance window."
  type        = string
  default     = "FREQ=WEEKLY;BYDAY=SA,SU"
}

variable "deletion_protection" {
  description = "Block accidental terraform destroy of the cluster."
  type        = bool
  default     = false
}

variable "cluster_timeout" {
  description = "Timeout for cluster and node pool operations."
  type        = string
  default     = "40m"
}

variable "labels" {
  description = "Extra resource labels on the cluster."
  type        = map(string)
  default     = {}
}

variable "emulated_cluster_token" {
  description = "Static bearer token used in the emulated kubeconfig. Local only."
  type        = string
  default     = "floci-mock-access-token"
  sensitive   = true
}
