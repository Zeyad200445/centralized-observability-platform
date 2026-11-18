# ===========================================================================
# LOCAL environment - state lives on disk next to this file.
#
# No GCS backend: the emulator's own storage service would be a circular
# dependency (Terraform needs the backend before it can create the bucket
# that is the backend). Local state is also disposable, which is the point.
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

  backend "local" {
    path = "terraform.tfstate"
  }
}
