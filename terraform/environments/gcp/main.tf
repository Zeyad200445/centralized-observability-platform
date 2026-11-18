# ===========================================================================
# GCP environment.
#
# Compare this file to environments/local/main.tf: the module source and the
# argument names are identical. Promotion is switching directory, not
# rewriting infrastructure.
# ===========================================================================

# Enable the APIs the stack depends on. Ordered before everything else by the
# data dependency in module.observability below.
resource "google_project_service" "required" {
  for_each = toset(var.enable_apis ? [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "artifactregistry.googleapis.com",
  ] : [])

  project = var.project_id
  service = each.value

  # Never turn an API off underneath a live cluster.
  disable_on_destroy         = false
  disable_dependent_services = false
}

module "observability" {
  source = "../../stack"

  project_id  = var.project_id
  region      = var.region
  environment = "gcp"
  name_prefix = var.name_prefix

  # Real cloud: every hardened feature the local run had to skip is on.
  emulated = false

  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  master_ipv4_cidr_block     = var.master_ipv4_cidr_block
  authorized_source_ranges   = var.authorized_source_ranges
  master_authorized_networks = var.master_authorized_networks

  enable_private_nodes = true
  enable_cloud_nat     = true
  enable_flow_logs     = var.enable_flow_logs

  kubernetes_version = var.kubernetes_version
  release_channel    = var.release_channel

  machine_type       = var.machine_type
  disk_size_gb       = var.disk_size_gb
  node_count         = var.node_count
  enable_autoscaling = var.enable_autoscaling
  min_node_count     = var.min_node_count
  max_node_count     = var.max_node_count

  deletion_protection = var.deletion_protection

  # Identical to the local values; the Workload Identity binding depends on
  # these matching what Ansible creates in-cluster.
  monitoring_namespace         = "monitoring"
  exporter_k8s_service_account = "gcp-exporter-sa"
  exporter_token_creators      = var.exporter_token_creators

  create_artifacts_bucket  = var.create_artifacts_bucket
  artifacts_retention_days = var.artifacts_retention_days

  labels = var.labels

  depends_on = [google_project_service.required]
}
