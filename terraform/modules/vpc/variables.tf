variable "project_id" {
  description = "GCP project ID (or the emulator's default project locally)."
  type        = string
}

variable "region" {
  description = "Region hosting the subnetwork and the regional GKE cluster."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every network resource name."
  type        = string
  default     = "obs"
}

variable "subnet_cidr" {
  description = "Primary CIDR for GKE worker node internal IPs."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "pods_range_name" {
  description = "Name of the secondary range used for Kubernetes Pod IPs."
  type        = string
  default     = "obs-pods"
}

variable "pods_cidr" {
  description = "Secondary CIDR for Pod IPs. Must be large: GKE carves a /24 per node."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a valid IPv4 CIDR block."
  }
}

variable "services_range_name" {
  description = "Name of the secondary range used for Kubernetes Service ClusterIPs."
  type        = string
  default     = "obs-services"
}

variable "services_cidr" {
  description = "Secondary CIDR for Service ClusterIPs."
  type        = string
  default     = "10.30.0.0/20"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a valid IPv4 CIDR block."
  }
}

variable "master_ipv4_cidr_block" {
  description = "CIDR of the GKE control plane, used as a firewall source range."
  type        = string
  default     = "172.16.0.0/28"
}

variable "node_network_tag" {
  description = "Network tag attached to GKE nodes and targeted by firewall rules."
  type        = string
  default     = "obs-gke-node"
}

variable "authorized_source_ranges" {
  description = "Trusted CIDRs allowed to reach SSH and the NodePort range."
  type        = list(string)
  default     = []
}

variable "routing_mode" {
  description = "VPC routing mode: REGIONAL or GLOBAL."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "GLOBAL"], var.routing_mode)
    error_message = "routing_mode must be REGIONAL or GLOBAL."
  }
}

variable "mtu" {
  description = "VPC MTU in bytes."
  type        = number
  default     = 1460
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs on the subnet. Off locally (emulator does not model them)."
  type        = bool
  default     = false
}

variable "enable_cloud_nat" {
  description = "Create Cloud Router + Cloud NAT for private node egress. Off locally."
  type        = bool
  default     = false
}
