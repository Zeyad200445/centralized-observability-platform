output "project_id" {
  description = "Emulated project ID."
  value       = module.observability.project_id
}

output "region" {
  description = "Region used."
  value       = module.observability.region
}

output "cluster_name" {
  description = "Name of the emulated GKE cluster (k3s container behind it)."
  value       = module.observability.cluster_name
}

output "network_name" {
  description = "VPC network name."
  value       = module.observability.network_name
}

output "subnet_name" {
  description = "Subnetwork name."
  value       = module.observability.subnet_name
}

output "node_service_account_email" {
  description = "Node service account email."
  value       = module.observability.node_service_account_email
}

output "gcp_exporter_service_account_email" {
  description = "Exporter SA email. Goes into the K8s SA annotation."
  value       = module.observability.gcp_exporter_service_account_email
}

output "workload_identity_member" {
  description = "Workload Identity principal string."
  value       = module.observability.workload_identity_member
}

output "artifacts_bucket" {
  description = "Emulated GCS bucket name."
  value       = module.observability.artifacts_bucket
}

# `make kubeconfig` pipes this into .floci/kubeconfig.
output "kubeconfig" {
  description = "Kubeconfig for the emulated cluster."
  value       = module.observability.kubeconfig
  sensitive   = true
}

output "ansible_facts" {
  description = "Handoff payload consumed by the Ansible playbook."
  value       = module.observability.ansible_facts
}
