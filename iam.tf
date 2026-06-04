###############################################################################
# Dedicated service accounts per VM — least privilege.
###############################################################################

resource "google_service_account" "prod_vm" {
  account_id   = "${var.name_prefix}-prod-vm"
  display_name = "ProtectPortal Production VM"
  description  = "Runtime identity for the production ProtectPortal VM."
}

resource "google_service_account" "dr_vm" {
  account_id   = "${var.name_prefix}-dr-vm"
  display_name = "ProtectPortal DR VM"
  description  = "Runtime identity for the ProtectPortal disaster-recovery VM."
}

# Roles common to both VMs: write logs/metrics, pull container images if needed.
locals {
  vm_runtime_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
}

resource "google_project_iam_member" "prod_vm_roles" {
  for_each = local.vm_runtime_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.prod_vm.email}"
}

resource "google_project_iam_member" "dr_vm_roles" {
  for_each = local.vm_runtime_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.dr_vm.email}"
}
