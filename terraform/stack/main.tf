# ===========================================================================
# stack/ - the single composition root.
#
# Both environments (local emulator, real GCP) instantiate THIS module and
# nothing else. That is what makes "promotion" a one-line change: the graph
# of resources is byte-identical, only the provider endpoints, the backend
# and a handful of sizing variables differ.
#
# Order is enforced by data flow, not by depends_on:
#   vpc  -> network/subnet IDs    -> gke
#   iam  -> node SA email         -> gke
#   gke  -> endpoint + CA         -> kubeconfig output -> Ansible
# ===========================================================================

locals {
  name_prefix = var.name_prefix

  common_labels = merge(
    {
      platform    = "centralized-observability"
      environment = var.environment
      managed-by  = "terraform"
    },
    var.labels,
  )
}

module "vpc" {
  source = "../modules/vpc"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  subnet_cidr         = var.subnet_cidr
  pods_range_name     = "${local.name_prefix}-pods"
  pods_cidr           = var.pods_cidr
  services_range_name = "${local.name_prefix}-services"
  services_cidr       = var.services_cidr

  master_ipv4_cidr_block   = var.master_ipv4_cidr_block
  node_network_tag         = "${local.name_prefix}-gke-node"
  authorized_source_ranges = var.authorized_source_ranges

  # Flow logs and Cloud NAT are real-GCP concerns the emulator does not model.
  enable_flow_logs = var.emulated ? false : var.enable_flow_logs
  enable_cloud_nat = var.emulated ? false : var.enable_cloud_nat
}

module "iam" {
  source = "../modules/iam"

  project_id = var.project_id

  node_sa_account_id     = var.node_sa_account_id
  exporter_sa_account_id = var.exporter_sa_account_id

  # Must match the ServiceAccount Ansible creates and the exporter pod uses.
  exporter_k8s_namespace       = var.monitoring_namespace
  exporter_k8s_service_account = var.exporter_k8s_service_account

  enable_artifact_registry_pull = !var.emulated
  exporter_can_list_resources   = var.exporter_can_list_resources
  exporter_token_creators       = var.exporter_token_creators
}

module "gke" {
  source = "../modules/gke"

  project_id   = var.project_id
  location     = var.region
  environment  = var.environment
  cluster_name = "${local.name_prefix}-gke"
  emulated     = var.emulated

  network             = module.vpc.network_id
  subnetwork          = module.vpc.subnet_id
  pods_range_name     = module.vpc.pods_range_name
  services_range_name = module.vpc.services_range_name
  node_network_tag    = module.vpc.node_network_tag

  enable_private_nodes       = var.emulated ? false : var.enable_private_nodes
  enable_private_endpoint    = false
  master_ipv4_cidr_block     = var.master_ipv4_cidr_block
  master_authorized_networks = var.master_authorized_networks

  kubernetes_version = var.kubernetes_version
  release_channel    = var.emulated ? "UNSPECIFIED" : var.release_channel

  node_pool_name             = "${local.name_prefix}-node-pool"
  node_service_account_email = module.iam.node_service_account_email
  machine_type               = var.machine_type
  disk_size_gb               = var.disk_size_gb
  node_count                 = var.node_count
  enable_autoscaling         = var.emulated ? false : var.enable_autoscaling
  min_node_count             = var.min_node_count
  max_node_count             = var.max_node_count
  oauth_scopes               = var.oauth_scopes

  deletion_protection    = var.deletion_protection
  emulated_cluster_token = var.emulated_cluster_token

  labels = local.common_labels
}

# ---------------------------------------------------------------------------
# State bucket for the ELK snapshot repository / Terraform remote state in the
# cloud environment. Created only when asked for, and never locally.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "observability_artifacts" {
  count = var.create_artifacts_bucket ? 1 : 0

  project                     = var.project_id
  name                        = "${local.name_prefix}-artifacts-${var.project_id}"
  location                    = var.region
  force_destroy               = var.emulated
  uniform_bucket_level_access = true
  storage_class               = "STANDARD"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.artifacts_retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = local.common_labels
}

# The exporter reads bucket metrics from the Monitoring API; it needs no
# direct bucket IAM. Granting object read here would be scope creep.
