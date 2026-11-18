output "project_id" {
  description = "Project the stack was deployed into."
  value       = module.observability.project_id
}

output "region" {
  description = "Region used. `make gcp-kubeconfig` reads this."
  value       = module.observability.region
}

output "cluster_name" {
  description = "GKE cluster name. `make gcp-kubeconfig` reads this."
  value       = module.observability.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.observability.cluster_endpoint
  sensitive   = true
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
  description = "Exporter SA email for the iam.gke.io/gcp-service-account annotation."
  value       = module.observability.gcp_exporter_service_account_email
}

output "workload_identity_pool" {
  description = "Workload Identity pool of the cluster."
  value       = module.observability.workload_identity_pool
}

output "workload_identity_member" {
  description = "Principal string used in the workloadIdentityUser binding."
  value       = module.observability.workload_identity_member
}

output "artifacts_bucket" {
  description = "GCS artifacts bucket name."
  value       = module.observability.artifacts_bucket
}

output "ansible_facts" {
  description = "Handoff payload consumed by the Ansible playbook."
  value       = module.observability.ansible_facts
}

output "connect_command" {
  description = "Copy-paste command to get cluster credentials."
  value       = "gcloud container clusters get-credentials ${module.observability.cluster_name} --region ${module.observability.region} --project ${module.observability.project_id}"
}
