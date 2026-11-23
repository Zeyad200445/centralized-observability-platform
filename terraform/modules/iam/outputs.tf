output "node_service_account_email" {
  value = data.google_compute_default_service_account.default.email
}

output "node_service_account_id" {
  value = data.google_compute_default_service_account.default.name
}

output "exporter_service_account_email" {
  value = data.google_compute_default_service_account.default.email
}

output "exporter_service_account_id" {
  value = data.google_compute_default_service_account.default.name
}

output "exporter_k8s_service_account" {
  value = "${var.exporter_k8s_namespace}/${var.exporter_k8s_service_account}"
}

output "workload_identity_member" {
  value = local.k8s_sa_member
}

output "node_sa_roles" {
  value = local.node_sa_roles
}

output "exporter_sa_roles" {
  value = local.exporter_sa_roles
}
