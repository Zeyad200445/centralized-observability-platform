output "node_service_account_email" {
  description = "Email of the GKE node service account, attached to the node pool."
  value       = google_service_account.gke_node.email
}

output "node_service_account_id" {
  description = "Fully qualified resource name of the node service account."
  value       = google_service_account.gke_node.name
}

output "exporter_service_account_email" {
  description = "Email of the GCP metrics exporter SA. Ansible annotates the K8s SA with this."
  value       = google_service_account.gcp_exporter.email
}

output "exporter_service_account_id" {
  description = "Fully qualified resource name of the exporter service account."
  value       = google_service_account.gcp_exporter.name
}

output "exporter_k8s_service_account" {
  description = "Namespace/name of the Kubernetes SA bound via Workload Identity."
  value       = "${var.exporter_k8s_namespace}/${var.exporter_k8s_service_account}"
}

output "workload_identity_member" {
  description = "The principal string used in the workloadIdentityUser binding."
  value       = local.k8s_sa_member
}

output "node_sa_roles" {
  description = "Resolved list of roles granted to the node service account."
  value       = local.node_sa_roles
}

output "exporter_sa_roles" {
  description = "Resolved list of roles granted to the exporter service account."
  value       = local.exporter_sa_roles
}
