output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "cluster_id" {
  description = "Fully qualified cluster ID."
  value       = google_container_cluster.this.id
}

output "location" {
  description = "Region or zone the cluster lives in."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Kubernetes API server endpoint. Ansible builds its kubeconfig from this."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64 DER of the cluster CA, for the kubeconfig."
  value       = try(google_container_cluster.this.master_auth[0].cluster_ca_certificate, "")
  sensitive   = true
}

output "workload_identity_pool" {
  description = "Workload Identity pool, i.e. <project>.svc.id.goog."
  value       = try(google_container_cluster.this.workload_identity_config[0].workload_pool, "")
}

output "node_pool_name" {
  description = "Name of the managed node pool."
  value       = try(google_container_node_pool.this[0].name, "")
}

output "node_service_account_email" {
  description = "Service account the nodes actually run as."
  value       = var.node_service_account_email
}

output "master_version" {
  description = "Control plane version GKE settled on."
  value       = google_container_cluster.this.master_version
}

# ---------------------------------------------------------------------------
# A ready-to-use kubeconfig. Emitted here rather than shelled out to gcloud so
# that the local flow needs no Google SDK at all: `make kubeconfig` just
# redirects this output into a file and Ansible uses it immediately.
# ---------------------------------------------------------------------------
output "kubeconfig" {
  description = "Rendered kubeconfig for the cluster."
  sensitive   = true
  value = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = google_container_cluster.this.name
    clusters = [{
      name = google_container_cluster.this.name
      cluster = merge(
        { server = "https://${google_container_cluster.this.endpoint}" },
        try(google_container_cluster.this.master_auth[0].cluster_ca_certificate, "") != ""
        ? { certificate-authority-data = google_container_cluster.this.master_auth[0].cluster_ca_certificate }
        : { insecure-skip-tls-verify = true }
      )
    }]
    contexts = [{
      name = google_container_cluster.this.name
      context = {
        cluster   = google_container_cluster.this.name
        user      = google_container_cluster.this.name
        namespace = "default"
      }
    }]
    users = [{
      name = google_container_cluster.this.name
      user = yamldecode(var.emulated ? yamlencode({
        token = var.emulated_cluster_token
      }) : yamlencode({
        exec = {
          apiVersion         = "client.authentication.k8s.io/v1beta1"
          command            = "gke-gcloud-auth-plugin"
          installHint        = "Install gke-gcloud-auth-plugin: gcloud components install gke-gcloud-auth-plugin"
          provideClusterInfo = true
        }
      }))
    }]
  })
}