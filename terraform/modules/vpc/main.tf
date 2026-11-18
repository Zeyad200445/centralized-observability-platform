# ===========================================================================
# modules/vpc - custom VPC-native networking for the observability GKE cluster
#
# GKE is created as a VPC-native (alias IP) cluster. That requires three
# distinct, non-overlapping CIDR ranges on one subnetwork:
#
#   primary            -> worker node internal IPs
#   secondary "pods"   -> one /24 carved per node for Pod IPs
#   secondary "svcs"   -> ClusterIP range for Services
#
# Pod IPs being routable inside the VPC is what lets Prometheus scrape pods
# directly and Filebeat ship to Logstash without any NAT hop.
# ===========================================================================

resource "google_compute_network" "this" {
  project                         = var.project_id
  name                            = "${var.name_prefix}-vpc"
  description                     = "Custom VPC for the centralized observability platform"
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = false
  mtu                             = var.mtu
}

resource "google_compute_subnetwork" "this" {
  project       = var.project_id
  name          = "${var.name_prefix}-subnet"
  description   = "Regional subnet hosting GKE worker nodes, pods and services"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr

  # Lets nodes reach *.googleapis.com (Artifact Registry, Cloud Monitoring API
  # for the Stackdriver exporter) without external IPs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = var.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = var.services_range_name
    ip_cidr_range = var.services_cidr
  }

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# ---------------------------------------------------------------------------
# Firewall: east-west traffic inside the cluster.
# Covers Filebeat -> Logstash:5044, Logstash -> Elasticsearch:9200,
# Prometheus -> exporters:9100/8080/9255 and Grafana -> Prometheus:9090.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_internal" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-internal"
  network     = google_compute_network.this.name
  description = "Allow all intra-cluster traffic between nodes, pods and services"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
  ]

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }
}

# ---------------------------------------------------------------------------
# Firewall: GKE control plane -> kubelet / webhooks.
# The Prometheus Operator admission webhook and metrics-server both need the
# master to reach ports 8443/9443/10250 on the nodes.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_master_webhooks" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-master-webhooks"
  network     = google_compute_network.this.name
  description = "Allow the GKE control plane to reach kubelet and admission webhooks"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.master_ipv4_cidr_block]
  target_tags   = [var.node_network_tag]

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "9443", "10250", "15017"]
  }
}

# ---------------------------------------------------------------------------
# Firewall: operator / CI access to the Kubernetes API and NodePorts.
# Locked to var.authorized_source_ranges rather than 0.0.0.0/0.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_admin" {
  count = length(var.authorized_source_ranges) > 0 ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-allow-admin"
  network     = google_compute_network.this.name
  description = "Operator access to NodePort range and SSH from trusted CIDRs"
  direction   = "INGRESS"
  priority    = 1100

  source_ranges = var.authorized_source_ranges
  target_tags   = [var.node_network_tag]

  allow {
    protocol = "tcp"
    ports    = ["22", "30000-32767"]
  }
}

# ---------------------------------------------------------------------------
# Cloud Router + Cloud NAT for private nodes.
# Disabled locally: k3s containers already have Docker-bridge egress and the
# emulator does not model NAT gateways.
# ---------------------------------------------------------------------------
resource "google_compute_router" "this" {
  count = var.enable_cloud_nat ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count = var.enable_cloud_nat ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-nat"
  region  = var.region
  router  = google_compute_router.this[0].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
