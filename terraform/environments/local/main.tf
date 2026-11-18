# ===========================================================================
# LOCAL environment - identical module graph to environments/gcp.
#
# The ONLY differences are:
#   * provider endpoints          (providers.tf)
#   * backend                     (versions.tf)
#   * emulated = true and smaller sizing (below)
#
# Nothing about the VPC, IAM or GKE resource shapes changes, which is what
# makes the local run a meaningful rehearsal rather than a toy.
# ===========================================================================

module "observability" {
  source = "../../stack"

  project_id  = var.project_id
  region      = var.region
  environment = "local"
  name_prefix = var.name_prefix

  # Tells the shared modules to skip GKE features k3s cannot model:
  # private nodes, shielded VMs, release channels, Cloud NAT, flow logs.
  emulated               = true
  emulated_cluster_token = var.emulator_access_token

  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  # One k3s container is the whole "node pool" locally.
  node_count         = 1
  enable_autoscaling = false
  machine_type       = "e2-standard-2"
  disk_size_gb       = 50

  enable_private_nodes = false
  enable_cloud_nat     = false
  enable_flow_logs     = false
  deletion_protection  = false

  # Must match ansible/group_vars/all.yml -> monitoring_namespace and the
  # ServiceAccount name in templates/gcp-exporter.yml.j2.
  monitoring_namespace         = "monitoring"
  exporter_k8s_service_account = "gcp-exporter-sa"

  # Exercises the emulator's GCS surface so the cloud path is pre-validated.
  create_artifacts_bucket = true

  labels = {
    environment = "local"
    emulator    = "floci-gcp"
  }
}
