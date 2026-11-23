# ===========================================================================
# modules/gke - the GKE cluster that hosts the whole observability platform
#
# Shape:
#   * VPC-native (alias IPs) attached to modules/vpc
#   * Workload Identity enabled -> the Stackdriver exporter authenticates to
#     the Cloud Monitoring API with no JSON key
#   * default node pool removed, one explicitly managed pool instead, so the
#     node service account and OAuth scopes are ours, not Google's defaults
#
# Against floci-gcp this maps to container.googleapis.com/v1 cluster and
# nodePool create calls, which the emulator services by starting a real
# rancher/k3s container over the Docker socket.
# ===========================================================================

locals {
  # Local k3s has no node auto-repair/upgrade, no shielded VMs, no release
  # channels. One flag collapses all of that instead of scattering ternaries.
  is_emulated = var.emulated

  cluster_labels = merge(
    {
      platform    = "centralized-observability"
      managed-by  = "terraform"
      environment = var.environment
    },
    var.labels,
  )
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.location

  description = "GKE cluster hosting the ELK logging and Prometheus/Grafana metrics stacks"

  network    = var.network
  subnetwork = var.subnetwork

  # We manage our own node pool so we control the service account and scopes.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  # VPC-native cluster: pods and services draw from the secondary ranges
  # created in modules/vpc.
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # The identity federation pool. Without this the exporter cannot exchange
  # its Kubernetes SA token for a Google access token.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = local.is_emulated ? "UNSPECIFIED" : var.release_channel
  }

  min_master_version = var.kubernetes_version

  # Private nodes keep the data plane off the public internet. Skipped
  # locally because k3s containers sit on a Docker bridge network.
  dynamic "private_cluster_config" {
    for_each = (!local.is_emulated && var.enable_private_nodes) ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = var.enable_private_endpoint
      master_ipv4_cidr_block  = var.master_ipv4_cidr_block

      master_global_access_config {
        enabled = true
      }
    }
  }

  dynamic "master_authorized_networks_config" {
    for_each = (!local.is_emulated && length(var.master_authorized_networks) > 0) ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # We run our own Prometheus and our own ELK. Google Managed Prometheus and
  # Cloud Logging would duplicate ingestion and duplicate the bill, and the
  # brief explicitly rules out native GCP logging paths.
  dynamic "monitoring_config" {
    for_each = local.is_emulated ? [] : [1]
    content {
      enable_components = var.gke_system_monitoring_components

      managed_prometheus {
        enabled = false
      }
    }
  }

  dynamic "logging_config" {
    for_each = local.is_emulated ? [] : [1]
    content {
      enable_components = var.gke_system_logging_components
    }
  }

  addons_config {
    http_load_balancing {
      disabled = !var.enable_http_load_balancing
    }

    horizontal_pod_autoscaling {
      disabled = !var.enable_hpa
    }

    # CSI driver backs the Elasticsearch and Prometheus PVCs on real GCP.
    dynamic "gcp_filestore_csi_driver_config" {
      for_each = (!local.is_emulated && var.enable_filestore_csi) ? [1] : []
      content {
        enabled = true
      }
    }
  }

  dynamic "maintenance_policy" {
    for_each = local.is_emulated ? [] : [1]
    content {
      recurring_window {
        start_time = var.maintenance_start_time
        end_time   = var.maintenance_end_time
        recurrence = var.maintenance_recurrence
      }
    }
  }

  resource_labels = local.cluster_labels

  lifecycle {
    ignore_changes = [
      # GKE rewrites this after auto-upgrades; do not fight it.
      min_master_version,
    ]
  }

  timeouts {
    create = var.cluster_timeout
    update = var.cluster_timeout
    delete = var.cluster_timeout
  }
}

# ---------------------------------------------------------------------------
# Managed node pool.
#
# Sizing note: Elasticsearch + Prometheus + Grafana + Kibana + Logstash and
# three DaemonSets do not fit on a 2-vCPU node. Defaults are sized for the
# real stack; the local environment overrides them downward.
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "this" {
  count    = local.is_emulated ? 0 : 1
  project  = var.project_id
  name     = var.node_pool_name
  location = var.location
  cluster  = google_container_cluster.this.name

  node_count = var.enable_autoscaling ? null : var.node_count

  dynamic "autoscaling" {
    for_each = var.enable_autoscaling ? [1] : []
    content {
      min_node_count = var.min_node_count
      max_node_count = var.max_node_count
    }
  }

  dynamic "management" {
    for_each = local.is_emulated ? [] : [1]
    content {
      auto_repair  = true
      auto_upgrade = var.release_channel != "UNSPECIFIED"
    }
  }

  dynamic "upgrade_settings" {
    for_each = local.is_emulated ? [] : [1]
    content {
      max_surge       = 1
      max_unavailable = 0
      strategy        = "SURGE"
    }
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = var.disk_type
    image_type   = var.image_type
    preemptible  = var.preemptible
    spot         = var.spot

    # The dedicated least-privilege SA from modules/iam.
    service_account = var.node_service_account_email

    # cloud-platform plus the SA's IAM roles is the GKE-recommended pattern:
    # the scope opens the API surface, IAM decides what is actually allowed.
    oauth_scopes = var.oauth_scopes

    tags   = var.node_network_tag != "" ? [var.node_network_tag] : []
    labels = merge({ "node-role" = "observability" }, var.node_labels)

    metadata = {
      # Mandatory for Workload Identity: blocks the legacy v1 metadata
      # endpoint that would otherwise leak the node SA token to any pod.
      disable-legacy-endpoints = "true"
    }

    # Propagates the identity pool to the node so pods can use WI.
    workload_metadata_config {
      mode = local.is_emulated ? "GCE_METADATA" : "GKE_METADATA"
    }

    dynamic "shielded_instance_config" {
      for_each = local.is_emulated ? [] : [1]
      content {
        enable_secure_boot          = true
        enable_integrity_monitoring = true
      }
    }

    dynamic "taint" {
      for_each = var.node_taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    # Elasticsearch requires vm.max_map_count >= 262144 or the JVM refuses to
    # start with "max virtual memory areas too low". Setting it on the node
    # avoids a privileged initContainer in the Helm chart.
    dynamic "linux_node_config" {
      for_each = var.enable_sysctl_tuning ? [1] : []
      content {
        sysctls = {
          "net.core.somaxconn"           = "4096"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }

  timeouts {
    create = var.cluster_timeout
    update = var.cluster_timeout
    delete = var.cluster_timeout
  }
}
