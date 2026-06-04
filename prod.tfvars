# =============================================================================
# Production overrides for the ProtectPortal Terraform stack.
# -----------------------------------------------------------------------------
# Copy this file to prod.tfvars and fill in. Apply with:
#   terraform plan  -var-file prod.tfvars -out tfplan
#   terraform apply tfplan
#
# Remember to point Terraform at the production state bucket first:
#   terraform init -reconfigure `
#     -backend-config="bucket=iacat-prod-tfstate" `
#     -backend-config="prefix=protectportal/prod"
# =============================================================================

# Required ------------------------------------------------------------------
#project_id  = "protectportal"
project_id  = "protectportal-498318"
#domain_name = "protectportal.iacat.gov.ph"
domain_name = "iacat.quanbyit.com"
alert_email = "devops@quanbyit.com"

# Naming --------------------------------------------------------------------
# Production uses the default name_prefix (no -test suffix) so resources are
# named e.g. "protectportal-prod" rather than "ppt-test-prod".
name_prefix = "protectportal"
environment = "prod"

# HTTPS is on for production (the default; included here for clarity) ------
enable_https = true

# Safety guards stay on for production --------------------------------------
enable_deletion_protection = true
enable_snapshot_schedule   = true

# Production sizing per the original procurement spec -----------------------
# Prod VM: 16 vCPU / 64 GB RAM, 50 GB SSD boot, 2 TB SSD data
prod_machine_type      = "n2-standard-16"
prod_boot_disk_size_gb = 50
prod_boot_disk_type    = "pd-ssd"
prod_data_disk_size_gb = 2048
prod_data_disk_type    = "pd-ssd"

# DR VM: 4 vCPU / 8 GB RAM, 50 GB SSD boot, 500 GB pd-standard data
dr_machine_type      = "n2-custom-4-8192"
dr_boot_disk_size_gb = 50
dr_boot_disk_type    = "pd-ssd"
dr_data_disk_size_gb = 500
dr_data_disk_type    = "pd-standard"

# Optional: let Terraform manage the DNS A record if quanbyit.com is in
# Cloud DNS in this project. Leave commented if DNS lives at GoDaddy.
# create_dns_record = true
# dns_managed_zone  = "quanbyit-com"

# Optional: custom image PER VM. Each VM independently chooses either a
# disk image (boot disk only) OR a machine image (whole VM). Set ONE per VM.
# See docs/SHARED-IMAGE-GUIDE.md.
#
# Disk image (recommended -- keeps our separately-managed data disk pattern):
# prod_disk_image = "iacat-prod/protectportal-base-202606031430"   # pinned to one build
# prod_disk_image = "iacat-prod/family/protectportal-base"         # auto-picks latest
# dr_disk_image   = "iacat-prod/family/protectportal-base"
#
# Machine image (carries the source VM's data disk too -- see CAUTION below):
prod_machine_image = "projects/protectportal-498318/global/machineImages/prod-test-mi-1"
dr_machine_image   = "projects/protectportal-498318/global/machineImages/dr-test-mi-1"

# When using a machine image, set to true to let the MI's captured values for
# machine_type, scheduling, and shielded_instance_config WIN over our vars.
# Network, IAM, firewall tags, and OS Login metadata always override.
prod_inherit_from_machine_image = true
dr_inherit_from_machine_image   = true

# When the machine image ALREADY carries the data disk baked in, set these
# to false. Skips creating + attaching our separate google_compute_disk,
# skips the snapshot policy binding, and skips the mount script on boot.
# Default true keeps our prevent_destroy data-disk pattern intact.
prod_create_data_disk = false
dr_create_data_disk   = false
#
# CAUTION about machine images: they carry the source VM's data disk too. The
# separately-managed google_compute_disk.{prod_data,dr_data} resources still
# exist (snapshots keep working) but are NOT attached to the MI-restored VM --
# the MI's own data disk becomes the live disk. If you need the prevent_destroy
# data-disk pattern, use the disk-image path.
#
# Shortcut: shared_image sets both VMs to the same disk image:
# shared_image = "iacat-prod/protectportal-base-202606031430"

# Skip the per-VM PROVISIONING script. Use when the shared_image already
# includes everything (packages, ufw, SSH hardening, PostgreSQL cluster).
# The data-disk mount script (scripts/mount-data-disk-{prod,dr}.sh) ALWAYS
# runs regardless of this setting, so /data and /backups are always mounted.
run_startup_script = false
