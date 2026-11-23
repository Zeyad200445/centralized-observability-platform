locals {
  node_sa_roles = concat(
    [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/monitoring.viewer",
      "roles/stackdriver.resourceMetadata.writer",
    ],
    var.enable_artifact_registry_pull ? ["roles/artifactregistry.reader"] : [],
    var.additional_node_sa_roles,
  )

  exporter_sa_roles = concat(
    ["roles/monitoring.viewer"],
    var.exporter_can_list_resources ? ["roles/browser"] : [],
    var.additional_exporter_sa_roles,
  )

  k8s_sa_member = "serviceAccount:${var.project_id}.svc.id.goog[${var.exporter_k8s_namespace}/${var.exporter_k8s_service_account}]"
}

data "google_compute_default_service_account" "default" {
  project = var.project_id
}

resource "google_project_iam_member" "gke_node" {
  for_each = toset(local.node_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

