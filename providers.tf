provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.prod_zone

  default_labels = local.common_labels
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.prod_zone

  default_labels = local.common_labels
}
