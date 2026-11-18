# ===========================================================================
# Real Google Cloud. No custom endpoints: the provider talks to
# googleapis.com, exactly the surface the local run rehearsed.
#
# Credentials come from Application Default Credentials, in this order:
#   1. GOOGLE_APPLICATION_CREDENTIALS pointing at a key file
#   2. `gcloud auth application-default login` (developer laptops)
#   3. the attached service account / Workload Identity Federation (CI)
#
# Static key files are deliberately NOT referenced here. Option 3 is what CI
# should use; a committed key is the single most common GCP breach vector.
# ===========================================================================

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Quota and billing are attributed to the target project.
  billing_project       = var.project_id
  user_project_override = true

  request_timeout = "120s"

  default_labels = {
    platform    = "centralized-observability"
    managed-by  = "terraform"
    environment = "gcp"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  billing_project       = var.project_id
  user_project_override = true

  request_timeout = "120s"

  default_labels = {
    platform    = "centralized-observability"
    managed-by  = "terraform"
    environment = "gcp"
  }
}
