# ===========================================================================
# modules/iam - least-privilege identities for the observability platform
#
# Two separate GCP service accounts, deliberately NOT one:
#
#   1. obs-gke-node-sa      node identity. Write-only telemetry roles, plus
#                           artifact pull. Compromising a node must not grant
#                           the ability to read other projects' metrics.
#
#   2. obs-gcp-exporter-sa  workload identity for the Stackdriver exporter.
#                           roles/monitoring.viewer only: read metrics, write
#                           nothing. Never materialised as a JSON key file.
#
# The Workload Identity binding at the bottom is the bridge: it lets the
# Kubernetes SA monitoring/gcp-exporter-sa impersonate obs-gcp-exporter-sa
# through the GKE metadata server, so no static credential ever exists.
# ===========================================================================

locals {
  # Roles granted to the GKE node service account. Writer-only by design.
  node_sa_roles = concat(
    [
      "roles/logging.logWriter",          # node + kubelet logs
      "roles/monitoring.metricWriter",    # node resource metrics
      "roles/monitoring.viewer",          # read own metric descriptors
      "roles/stackdriver.resourceMetadata.writer",
    ],
    var.enable_artifact_registry_pull ? ["roles/artifactregistry.reader"] : [],
    var.additional_node_sa_roles,
  )

  # Roles granted to the Stackdriver exporter. Read-only by design.
  exporter_sa_roles = concat(
    [
      "roles/monitoring.viewer",  # list/read time series via the Monitoring API
    ],
    var.exporter_can_list_resources ? ["roles/browser"] : [],
    var.additional_exporter_sa_roles,
  )

  # Canonical member string for the Kubernetes SA inside the WI pool.
  k8s_sa_member = "serviceAccount:${var.project_id}.svc.id.goog[${var.exporter_k8s_namespace}/${var.exporter_k8s_service_account}]"
}

# ---------------------------------------------------------------------------
# 1. GKE node service account
# ---------------------------------------------------------------------------
resource "google_service_account" "gke_node" {
  project      = var.project_id
  account_id   = var.node_sa_account_id
  display_name = "Observability GKE Node Service Account"
  description  = "Least-privilege identity attached to GKE worker nodes. Telemetry write only."
}

resource "google_project_iam_member" "gke_node" {
  for_each = toset(local.node_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# ---------------------------------------------------------------------------
# 2. GCP Stackdriver exporter service account
# ---------------------------------------------------------------------------
resource "google_service_account" "gcp_exporter" {
  project      = var.project_id
  account_id   = var.exporter_sa_account_id
  display_name = "Observability GCP Metrics Exporter Service Account"
  description  = "Read-only identity used by prometheus-stackdriver-exporter via Workload Identity."
}

resource "google_project_iam_member" "gcp_exporter" {
  for_each = toset(local.exporter_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gcp_exporter.email}"
}

# ---------------------------------------------------------------------------
# 3. Workload Identity binding
#
# Grants roles/iam.workloadIdentityUser on the GCP SA to the Kubernetes SA.
# Once Ansible annotates monitoring/gcp-exporter-sa with
#   iam.gke.io/gcp-service-account: <exporter email>
# the GKE metadata server mints short-lived tokens for the exporter pod.
# ---------------------------------------------------------------------------
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.gcp_exporter.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.k8s_sa_member
}

# ---------------------------------------------------------------------------
# 4. Optional: allow the node SA to impersonate nothing, but allow named
#    human operators to impersonate the exporter SA for debugging.
# ---------------------------------------------------------------------------
resource "google_service_account_iam_member" "exporter_token_creators" {
  for_each = toset(var.exporter_token_creators)

  service_account_id = google_service_account.gcp_exporter.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}
