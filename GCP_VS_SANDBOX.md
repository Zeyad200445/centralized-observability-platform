# Production GCP vs. GCP Sandbox (`apply-on-gcp-sandbox`)

This document outlines the architectural and configuration differences between the production-ready GCP deployment on the `main` branch and the adapted deployment on the `apply-on-gcp-sandbox` branch (validated on a restricted Qwiklabs GCP Sandbox).

It also documents real-world GCP compatibility findings discovered during live GKE deployment that are applicable back to `main`.

---

## 1. High-Level Comparison Matrix

| Layer / Component | Production GCP (`main`) | GCP Sandbox (`apply-on-gcp-sandbox`) | Reason for Divergence |
| :--- | :--- | :--- | :--- |
| **Terraform Backend** | Remote GCS bucket (`backend "gcs"`) | Local state (`backend "local"`) | Sandbox projects are ephemeral (~1 hour); avoids unnecessary bucket lifecycle overhead. |
| **Region / Zone** | `us-central1` / `us-central1-a` | `us-east1` / `us-east1-b` | Sandbox enforces `constraints/gcp.resourceLocations` Organization Policy blocking `us-central1`. |
| **IAM Service Accounts** | 2 dedicated least-privilege SAs (`obs-gke-node-sa`, `obs-gcp-exporter-sa`) | Default Compute SA (`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com`) | Sandbox student user lacks `roles/iam.serviceAccountAdmin` (cannot create new SAs). |
| **Workload Identity Binding** | Enabled (`google_service_account_iam_member.workload_identity`) | Omitted from Terraform | Sandbox student user lacks `iam.serviceAccounts.setIamPolicy` permission. |
| **Elasticsearch Replicas** | Multi-node HA (3 replicas) | Single-node (`elasticsearch_replicas=1`) | Faster bootstrap and reduced quota footprint within lab time limits. |
| **Storage Sizing** | Production PVC sizes (`standard-rwo`) | `10Gi` for Elasticsearch & Prometheus (`standard-rwo`) | Fits sandbox disk quotas while still validating GKE PD-CSI dynamic provisioning. |
| **Elasticsearch Transport TLS** | Enabled (`is_emulated=false`) | Disabled (`xpack.security.transport.ssl.enabled: false`) | No TLS keystore/certificates pre-provisioned in the Helm chart for ES 8.5.1. |

---

## 2. Sandbox-Specific Adaptations (Not for `main`)

These changes exist strictly to work around Qwiklabs IAM and Org Policy guardrails and must remain isolated to `apply-on-gcp-sandbox`:

### 2.1 Ephemeral Terraform State (`terraform/environments/gcp/versions.tf`)
* Switched `backend "gcs"` to `backend "local"` and removed the `bucket` and `prefix` arguments.
* Local `.tfstate` files are excluded from Git and cleaned up between sandbox sessions.

### 2.2 Regional Org Policy Compliance (`terraform/environments/gcp/terraform.tfvars`)
* Updated `region` to `us-east1` and `zone` to `us-east1-b` after verifying allowed locations via `gcloud resource-manager org-policies describe constraints/gcp.resourceLocations`.

### 2.3 IAM & Workload Identity Fallback (`terraform/modules/iam/main.tf`)
* Replaced `resource "google_service_account"` blocks with a data lookup referencing the project's pre-existing Default Compute Engine Service Account.
* Removed `resource "google_service_account_iam_member" "workload_identity"` because `iam.serviceAccounts.setIamPolicy` returns `403 Forbidden` in the sandbox.
* **Trade-off:** While `gcp-stackdriver-exporter` deploys cleanly as a Kubernetes Deployment/ServiceMonitor, live GCP Monitoring API scraping via Workload Identity is deferred to unrestricted GCP environments.

### 2.4 Right-Sized Helm Overrides (Ansible CLI)
Passed JSON extra-vars at runtime to keep Ansible defaults intact while fitting sandbox quotas:
```bash
-e storage_class=standard-rwo \
-e elasticsearch_persistence_size=10Gi \
-e prometheus_persistence_size=10Gi \
-e '{"is_emulated": false, "elasticsearch_replicas": 1, "elasticsearch_tls_enabled": false}'