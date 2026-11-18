output "project_id" {
  description = "Project the stack was deployed into."
  value       = var.project_id
}

output "region" {
  description = "Region of the subnet and cluster."
  value       = var.region
}

output "network_name" {
  description = "VPC network name."
  value       = module.vpc.network_name
}

output "subnet_name" {
  description = "Subnetwork name."
  value       = module.vpc.subnet_name
}

output "pods_range_name" {
  description = "Secondary range name used for Pods."
  value       = module.vpc.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name used for Services."
  value       = module.vpc.services_range_name
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.gke.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64 cluster CA certificate."
  value       = module.gke.cluster_ca_certificate
  sensitive   = true
}

output "workload_identity_pool" {
  description = "Workload Identity pool of the cluster."
  value       = module.gke.workload_identity_pool
}

output "node_service_account_email" {
  description = "Email of the GKE node service account."
  value       = module.iam.node_service_account_email
}

output "gcp_exporter_service_account_email" {
  description = "Email Ansible must put in the iam.gke.io/gcp-service-account annotation."
  value       = module.iam.exporter_service_account_email
}

output "gcp_exporter_k8s_service_account" {
  description = "namespace/name of the Kubernetes SA bound via Workload Identity."
  value       = module.iam.exporter_k8s_service_account
}

output "workload_identity_member" {
  description = "Principal used in the workloadIdentityUser binding."
  value       = module.iam.workload_identity_member
}

output "artifacts_bucket" {
  description = "Artifacts/snapshot bucket name, empty when not created."
  value       = try(google_storage_bucket.observability_artifacts[0].name, "")
}

output "kubeconfig" {
  description = "Rendered kubeconfig for the cluster."
  value       = module.gke.kubeconfig
  sensitive   = true
}

# Single JSON blob consumed by Ansible via `terraform output -json`, so the
# playbook never has to guess the exporter SA email or namespace names.
output "ansible_facts" {
  description = "Handoff payload from Terraform to Ansible."
  value = {
    project_id                  = var.project_id
    region                      = var.region
    environment                 = var.environment
    emulated                    = var.emulated
    cluster_name                = module.gke.cluster_name
    workload_identity_pool      = module.gke.workload_identity_pool
    gcp_exporter_sa_email       = module.iam.exporter_service_account_email
    gcp_exporter_k8s_namespace  = var.monitoring_namespace
    gcp_exporter_k8s_sa_name    = var.exporter_k8s_service_account
    artifacts_bucket            = try(google_storage_bucket.observability_artifacts[0].name, "")
  }
}
