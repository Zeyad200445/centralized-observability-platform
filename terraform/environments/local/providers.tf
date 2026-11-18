# ===========================================================================
# Google provider pointed entirely at floci-gcp.
#
# Every *_custom_endpoint below replaces one googleapis.com host. The path
# suffixes are not cosmetic: the provider appends resource paths directly to
# these strings, so the version segment and the trailing slash must match
# what the real API uses.
#
#   real                                              -> emulated
#   https://compute.googleapis.com/compute/v1/         -> :4588/compute/v1/
#   https://container.googleapis.com/v1/               -> :4588/container/v1/
#   https://iam.googleapis.com/v1/                     -> :4588/v1/
#   https://storage.googleapis.com/storage/v1/         -> :4588/storage/v1/
#   https://monitoring.googleapis.com/v1/              -> :4588/v1/
#   https://serviceusage.googleapis.com/v1/            -> :4588/v1/
#   https://cloudresourcemanager.googleapis.com/v1/    -> :4588/v1/
#
# floci-gcp does not cryptographically validate credentials, but the provider
# refuses to initialise without a credential source, hence the static token.
# ===========================================================================

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  access_token          = var.emulator_access_token
  billing_project       = var.project_id
  user_project_override = false

  request_timeout = "120s"

  compute_custom_endpoint                = "${var.emulator_endpoint}/compute/v1/"
  container_custom_endpoint              = "${var.emulator_endpoint}/container/"
  iam_custom_endpoint                    = "${var.emulator_endpoint}/"
  iam_credentials_custom_endpoint        = "${var.emulator_endpoint}/"
  storage_custom_endpoint                = "${var.emulator_endpoint}/storage/v1/"
  monitoring_custom_endpoint             = "${var.emulator_endpoint}/"
  service_usage_custom_endpoint          = "${var.emulator_endpoint}/"
  resource_manager_custom_endpoint       = "${var.emulator_endpoint}/"
  resource_manager_v3_custom_endpoint    = "${var.emulator_endpoint}/"
  cloud_resource_manager_custom_endpoint = "${var.emulator_endpoint}/"
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  access_token          = var.emulator_access_token
  billing_project       = var.project_id
  user_project_override = false

  request_timeout = "120s"

  compute_custom_endpoint                = "${var.emulator_endpoint}/compute/v1/"
  container_custom_endpoint              = "${var.emulator_endpoint}/container/"
  iam_custom_endpoint                    = "${var.emulator_endpoint}/"
  iam_credentials_custom_endpoint        = "${var.emulator_endpoint}/"
  storage_custom_endpoint                = "${var.emulator_endpoint}/storage/v1/"
  monitoring_custom_endpoint             = "${var.emulator_endpoint}/"
  service_usage_custom_endpoint          = "${var.emulator_endpoint}/"
  resource_manager_custom_endpoint       = "${var.emulator_endpoint}/"
  resource_manager_v3_custom_endpoint    = "${var.emulator_endpoint}/"
  cloud_resource_manager_custom_endpoint = "${var.emulator_endpoint}/"
}