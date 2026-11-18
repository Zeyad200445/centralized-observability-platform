output "network_id" {
  description = "Fully qualified VPC network ID, consumed by the GKE module."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Short VPC network name."
  value       = google_compute_network.this.name
}

output "network_self_link" {
  description = "Self link of the VPC network."
  value       = google_compute_network.this.self_link
}

output "subnet_id" {
  description = "Fully qualified subnetwork ID, consumed by the GKE module."
  value       = google_compute_subnetwork.this.id
}

output "subnet_name" {
  description = "Short subnetwork name."
  value       = google_compute_subnetwork.this.name
}

output "subnet_cidr" {
  description = "Primary node CIDR actually provisioned."
  value       = google_compute_subnetwork.this.ip_cidr_range
}

output "pods_range_name" {
  description = "Secondary range name for Pods, passed to ip_allocation_policy."
  value       = var.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for Services, passed to ip_allocation_policy."
  value       = var.services_range_name
}

output "node_network_tag" {
  description = "Network tag that GKE nodes must carry for the firewall rules to apply."
  value       = var.node_network_tag
}
