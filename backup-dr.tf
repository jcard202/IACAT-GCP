###############################################################################
# GCP Backup & DR Service -- VM-level, application-consistent backups with
# immutable retention. Distinct from the disk snapshot policy in compute.tf
# (which protects only the data disks at the GCE-PD level).
#
# Architecture:
#   - Backup Vault     -- regional WORM store for backup data (immutable until
#                         vault's minimum retention elapses)
#   - Backup Plan      -- daily schedule + retention policy (applies to one
#                         resource type: compute.googleapis.com/Instance)
#   - Plan Association -- binds the plan to a specific VM
#
# Requires API: backupdr.googleapis.com (enabled by scripts/bootstrap.ps1).
#
# Cost: ~$50/mo per protected VM in vault storage + per-GB charges for
# backed-up disk data.
###############################################################################

resource "google_backup_dr_backup_vault" "main" {
  count    = var.enable_backup_dr ? 1 : 0
  location = var.region

  backup_vault_id = "${var.name_prefix}-backup-vault"
  description     = "Backup vault for ProtectPortal VMs (prod + DR), regional WORM store with immutable retention."

  # Vault-level WORM lock. Backups cannot be deleted before this duration
  # elapses -- even by Owner. Set to the same value as the plan's retention
  # so the plan's expiry matches the vault's enforced minimum.
  backup_minimum_enforced_retention_duration = "${var.backup_dr_retention_days * 86400}s"

  labels = local.common_labels

  # Vault deletion is intentionally hard: you must clear all backups first,
  # wait the WORM period, then delete. Marking prevent_destroy guards against
  # accidental `terraform destroy` wiping backup history during reset cycles.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_backup_dr_backup_plan" "daily" {
  count    = var.enable_backup_dr ? 1 : 0
  location = var.region

  backup_plan_id = "${var.name_prefix}-daily-backup"
  description    = "Daily backup of ProtectPortal VMs into the regional vault."
  resource_type  = "compute.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.main[0].id

  backup_rules {
    rule_id               = "daily"
    backup_retention_days = var.backup_dr_retention_days

    standard_schedule {
      recurrence_type = "DAILY"

      # The backup window is when the backup engine MAY start the run. The
      # actual backup completes shortly after start. 17-19 UTC = 01-03 SGT.
      backup_window {
        start_hour_of_day = var.backup_dr_window_start_hour_utc
        end_hour_of_day   = var.backup_dr_window_start_hour_utc + 2
      }

      time_zone = "UTC"
    }
  }
}

###############################################################################
# Plan associations -- one per protected VM. Location is the VM's REGION
# (where the vault + plan live), not the zone.
###############################################################################

resource "google_backup_dr_backup_plan_association" "prod" {
  count    = var.enable_backup_dr ? 1 : 0
  location = var.region

  backup_plan_association_id = "${var.name_prefix}-prod-association"
  resource_type              = "compute.googleapis.com/Instance"
  resource                   = local.prod_instance_self_link
  backup_plan                = google_backup_dr_backup_plan.daily[0].id
}

resource "google_backup_dr_backup_plan_association" "dr" {
  count    = var.enable_backup_dr ? 1 : 0
  location = var.region

  backup_plan_association_id = "${var.name_prefix}-dr-association"
  resource_type              = "compute.googleapis.com/Instance"
  resource                   = local.dr_instance_self_link
  backup_plan                = google_backup_dr_backup_plan.daily[0].id
}
