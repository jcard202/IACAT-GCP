###############################################################################
# Data disks -- created as standalone resources so they survive VM recreation.
#
# NOTE: `lifecycle { prevent_destroy = true }` is a Terraform meta-argument
# that must be a literal -- it cannot be driven by a variable. So the test
# tear-down workflow has an extra step (see docs/TESTING.md): run
#   terraform state rm 'google_compute_disk.prod_data' 'google_compute_disk.dr_data'
# before `terraform destroy`, then delete the orphaned disks with gcloud.
# For production this guard is exactly what you want.
###############################################################################

resource "google_compute_disk" "prod_data" {
  count = var.prod_create_data_disk ? 1 : 0
  name  = "${local.prod_name}-data"
  type  = var.prod_data_disk_type
  zone  = var.prod_zone
  size  = var.prod_data_disk_size_gb

  physical_block_size_bytes = 4096

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_disk" "dr_data" {
  count = var.dr_create_data_disk ? 1 : 0
  name  = "${local.dr_name}-data"
  type  = var.dr_data_disk_type
  zone  = var.dr_zone
  size  = var.dr_data_disk_size_gb

  lifecycle {
    prevent_destroy = true
  }
}

###############################################################################
# Production VM
###############################################################################

resource "google_compute_instance" "prod" {
  count        = var.prod_machine_image == "" ? 1 : 0
  name         = local.prod_name
  machine_type = var.prod_machine_type
  zone         = var.prod_zone

  tags = ["ssh-iap", "http-backend", "protectportal-prod"]

  labels = {
    role = "production"
    tier = "web"
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image  = local.prod_effective_disk_image
      size   = var.prod_boot_disk_size_gb
      type   = var.prod_boot_disk_type
      labels = { role = "boot" }
    }
  }

  dynamic "attached_disk" {
    for_each = var.prod_create_data_disk ? [1] : []
    content {
      source      = google_compute_disk.prod_data[0].id
      device_name = "protectportal-prod-data"
      mode        = "READ_WRITE"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.prod.id

    # Public IP for live traffic + initial admin access.
    # In a hardened deployment, remove this block and front the VM with the LB only.
    access_config {
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email  = google_service_account.prod_vm.email
    scopes = ["cloud-platform"]
  }

  # 24x7 with auto-restart on host maintenance / crash.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
    # CIDR allowed to reach PostgreSQL on this VM. Read by the startup
    # script to populate ufw and pg_hba.conf, so this stays in sync with
    # var.vpc_cidr_dr without baking the value into the script.
    db-allow-cidr = var.vpc_cidr_dr
  }

  # The data-disk mount script runs only when WE create the data disk
  # (var.prod_create_data_disk = true). When the image carries its own data
  # disk, the image is responsible for the mount; our script would fail to
  # find the device. The provisioning script is independently gated by
  # var.run_startup_script.
  metadata_startup_script = join("\n", concat(
    var.prod_create_data_disk ? [file("${path.module}/scripts/mount-data-disk-prod.sh")] : [],
    var.run_startup_script ? [file("${path.module}/scripts/startup-prod.sh")] : []
  ))

  deletion_protection = var.enable_deletion_protection

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      # Don't recreate the VM every time the startup script changes;
      # rerun it manually on the instance if needed.
      metadata_startup_script,
    ]
  }
}

###############################################################################
# Unmanaged instance group — required to plug the prod VM into the HTTPS LB.
###############################################################################

resource "google_compute_instance_group" "prod" {
  name      = "${local.prod_name}-ig"
  zone      = var.prod_zone
  network   = google_compute_network.vpc.id
  instances = [local.prod_instance_self_link]

  named_port {
    name = "http"
    port = 80
  }
}

###############################################################################
# DR VM
###############################################################################

resource "google_compute_instance" "dr" {
  count        = var.dr_machine_image == "" ? 1 : 0
  name         = local.dr_name
  machine_type = var.dr_machine_type
  zone         = var.dr_zone

  tags = ["ssh-iap", "protectportal-dr"]

  labels = {
    role = "disaster-recovery"
    tier = "backup"
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image  = local.dr_effective_disk_image
      size   = var.dr_boot_disk_size_gb
      type   = var.dr_boot_disk_type
      labels = { role = "boot" }
    }
  }

  dynamic "attached_disk" {
    for_each = var.dr_create_data_disk ? [1] : []
    content {
      source      = google_compute_disk.dr_data[0].id
      device_name = "protectportal-dr-data"
      mode        = "READ_WRITE"
    }
  }

  # DR VM has no public IP — egress via Cloud NAT, ingress via IAP only.
  network_interface {
    subnetwork = google_compute_subnetwork.dr.id
  }

  service_account {
    email  = google_service_account.dr_vm.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
  }

  metadata_startup_script = join("\n", concat(
    var.dr_create_data_disk ? [file("${path.module}/scripts/mount-data-disk-dr.sh")] : [],
    var.run_startup_script ? [file("${path.module}/scripts/startup-dr.sh")] : []
  ))

  deletion_protection = var.enable_deletion_protection

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [metadata_startup_script]
  }
}

###############################################################################
# Snapshot schedules — automatic backups of every persistent disk.
###############################################################################

resource "google_compute_resource_policy" "daily_snapshot" {
  count  = var.enable_snapshot_schedule ? 1 : 0
  name   = "${var.name_prefix}-daily-snapshot"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "17:00" # 01:00 SGT (UTC+8)
      }
    }

    retention_policy {
      max_retention_days    = 30
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }

    snapshot_properties {
      storage_locations = [var.region]
      labels            = { policy = "daily" }
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "prod_data_daily" {
  count = var.enable_snapshot_schedule && var.prod_create_data_disk ? 1 : 0
  name  = google_compute_resource_policy.daily_snapshot[0].name
  disk  = google_compute_disk.prod_data[0].name
  zone  = var.prod_zone
}

resource "google_compute_disk_resource_policy_attachment" "dr_data_daily" {
  count = var.enable_snapshot_schedule && var.dr_create_data_disk ? 1 : 0
  name  = google_compute_resource_policy.daily_snapshot[0].name
  disk  = google_compute_disk.dr_data[0].name
  zone  = var.dr_zone
}

###############################################################################
# Machine-image variants of the VMs.
#
# When var.prod_machine_image / var.dr_machine_image is set, the disk-image
# resources above are skipped (count = 0) and these wrappers run instead.
# Only one of the two definitions per VM is ever in state at a time.
#
# Most VM configuration (machine_type, network, service account, scheduling,
# metadata, etc.) is omitted here -- the machine image already carries all of
# it. To override anything from the MI, add the corresponding attribute below.
#
# CAUTION: a machine image includes every disk attached to the source VM at
# capture time. If that source VM had a data disk, the restored VM will have
# it too -- and our attached_disk block below will then attach OUR
# google_compute_disk.*_data on top, leaving the VM with two data disks.
# Build the machine image from a VM with the data disk DETACHED so the
# restore is boot-disk-only and our attached_disk wires up the right one.
###############################################################################

resource "google_compute_instance_from_machine_image" "prod" {
  provider             = google-beta
  count                = var.prod_machine_image != "" ? 1 : 0
  name                 = local.prod_name
  zone                 = var.prod_zone
  source_machine_image = var.prod_machine_image

  # Network / IAM / firewall tags / OS Login MUST override the MI -- they
  # reference resources that only exist in this project.
  tags = ["ssh-iap", "http-backend", "protectportal-prod"]

  labels = {
    role = "production"
    tier = "web"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.prod.id

    access_config {
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email  = google_service_account.prod_vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
    db-allow-cidr          = var.vpc_cidr_dr
  }

  metadata_startup_script = join("\n", concat(
    var.prod_create_data_disk ? [file("${path.module}/scripts/mount-data-disk-prod.sh")] : [],
    var.run_startup_script ? [file("${path.module}/scripts/startup-prod.sh")] : []
  ))

  # ---- Fields that CAN be inherited from the MI ----
  # When prod_inherit_from_machine_image = true: omit these so the MI's
  # captured values win. Default false: our vars override.
  machine_type = var.prod_inherit_from_machine_image ? null : var.prod_machine_type

  dynamic "scheduling" {
    for_each = var.prod_inherit_from_machine_image ? [] : [1]
    content {
      automatic_restart   = true
      on_host_maintenance = "MIGRATE"
      preemptible         = false
      provisioning_model  = "STANDARD"
    }
  }

  dynamic "shielded_instance_config" {
    for_each = var.prod_inherit_from_machine_image ? [] : [1]
    content {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }

  deletion_protection       = var.enable_deletion_protection
  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [metadata_startup_script]
  }
}

###############################################################################
# Standalone attached_disk resources for the machine-image path.
#
# `google_compute_instance_from_machine_image` makes attached_disk read-only
# (the API inherits whatever was attached to the source VM at MI capture
# time). To get our separately-managed prod_data / dr_data attached, we use
# the dedicated google_compute_attached_disk resource type, which is a
# stand-alone disk-to-instance binding. Only created when the machine-image
# path is in use; the disk-image path already attaches via attached_disk in
# the google_compute_instance block above.
#
# Note: the MI must NOT itself contain a disk with the same device_name --
# `google-protectportal-prod-data` -- or you'll have a name collision. If
# your MI's source VM had a data disk attached, capture the MI from a VM
# with that disk DETACHED.
###############################################################################

resource "google_compute_attached_disk" "prod_data" {
  count       = var.prod_machine_image != "" && var.prod_create_data_disk ? 1 : 0
  disk        = google_compute_disk.prod_data[0].id
  instance    = google_compute_instance_from_machine_image.prod[0].id
  device_name = "protectportal-prod-data"
  mode        = "READ_WRITE"
}

resource "google_compute_attached_disk" "dr_data" {
  count       = var.dr_machine_image != "" && var.dr_create_data_disk ? 1 : 0
  disk        = google_compute_disk.dr_data[0].id
  instance    = google_compute_instance_from_machine_image.dr[0].id
  device_name = "protectportal-dr-data"
  mode        = "READ_WRITE"
}

resource "google_compute_instance_from_machine_image" "dr" {
  provider             = google-beta
  count                = var.dr_machine_image != "" ? 1 : 0
  name                 = local.dr_name
  zone                 = var.dr_zone
  source_machine_image = var.dr_machine_image

  tags = ["ssh-iap", "protectportal-dr"]

  labels = {
    role = "disaster-recovery"
    tier = "backup"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.dr.id
    # DR has no public IP -- egress via Cloud NAT, ingress via IAP only.
  }

  service_account {
    email  = google_service_account.dr_vm.email
    scopes = ["cloud-platform"]
  }

  machine_type = var.dr_inherit_from_machine_image ? null : var.dr_machine_type

  dynamic "scheduling" {
    for_each = var.dr_inherit_from_machine_image ? [] : [1]
    content {
      automatic_restart   = true
      on_host_maintenance = "MIGRATE"
      preemptible         = false
      provisioning_model  = "STANDARD"
    }
  }

  dynamic "shielded_instance_config" {
    for_each = var.dr_inherit_from_machine_image ? [] : [1]
    content {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
  }

  metadata_startup_script = join("\n", concat(
    var.dr_create_data_disk ? [file("${path.module}/scripts/mount-data-disk-dr.sh")] : [],
    var.run_startup_script ? [file("${path.module}/scripts/startup-dr.sh")] : []
  ))

  deletion_protection       = var.enable_deletion_protection
  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [metadata_startup_script]
  }
}
