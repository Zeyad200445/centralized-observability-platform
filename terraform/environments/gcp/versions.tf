# ===========================================================================
# GCP environment - remote state in GCS.
#
# GCS backend locking is automatic: the backend writes a <key>.tflock object
# and relies on object generation preconditions, so no DynamoDB-equivalent is
# needed. The bucket MUST have versioning enabled and MUST NOT be managed by
# this same root module (chicken and egg) - create it once, out of band:
#
#   gsutil mb -p <PROJECT> -l <REGION> gs://<PREFIX>-tfstate
#   gsutil versioning set on gs://<PREFIX>-tfstate
#
# Backend blocks cannot interpolate variables, so the values are supplied at
# init time:
#
#   terraform init \
#     -backend-config="bucket=<PREFIX>-tfstate" \
#     -backend-config="prefix=observability/gcp"
# ===========================================================================
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.44.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.44.0"
    }
  }

  backend "gcs" {
    # Overridden by -backend-config at init time.
    bucket = "CHANGE-ME-tfstate"
    prefix = "observability/gcp"
  }
}
