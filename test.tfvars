# =============================================================================
# Test / sandbox overrides
# -----------------------------------------------------------------------------
# Apply with (use the SPACE form on PowerShell; the `=` form breaks):
#   terraform plan  -var-file test.tfvars -out tfplan
#   terraform apply tfplan
#
# Deploys the same architecture as production but with absolute-minimum sizes
# so you can validate the stack end-to-end for a few dollars.
#
# Approximate cost while running 24/7 (asia-southeast1, on-demand):
#   2 × e2-micro VM           ~$14 / month  (1 hits the GCP free tier)
#   2 × 10 GB pd-standard boot ~$0.80 / month
#   2 × 10 GB pd-standard data ~$0.80 / month
#   HTTPS LB + Cloud Armor    ~$25 / month idle
#   Cloud NAT                 ~$1 / month idle
#   --------------------------------------
#   ~$42 / month, or ~$0.06 / hour
#
# Destroy the stack when you're done (see docs/TESTING.md) and the cost drops
# to ~$0 (a few cents for retained snapshots if you didn't disable them).
# =============================================================================

# Required — fill these in even for test:
project_id  = "iacat-test"
domain_name = "iacat-test.quanbyit.com"
alert_email = "devops@quanbyit.com"

# Distinct name so resources don't collide with a prod deploy:
name_prefix = "ppt-test"
environment = "test"

# ---- Smallest practical machine types ---------------------------------------
# e2-micro = 2 vCPU shared, 1 GB RAM. Cheapest GCE VM. 1 instance / region is
# covered by the GCP free tier each month.
prod_machine_type = "e2-micro"
dr_machine_type   = "e2-micro"

# ---- Smallest disks ---------------------------------------------------------
# 10 GB is the minimum Ubuntu boot disk. pd-standard (HDD) is the cheapest type.
prod_boot_disk_size_gb = 13
prod_boot_disk_type    = "pd-standard"
prod_data_disk_size_gb = 11
prod_data_disk_type    = "pd-standard"

dr_boot_disk_size_gb = 14
dr_boot_disk_type    = "pd-standard"
dr_data_disk_size_gb = 12
dr_data_disk_type    = "pd-standard"

# ---- Test-friendly safety overrides ----------------------------------------
# Lets `terraform destroy` actually delete the VMs without a manual edit.
enable_deletion_protection = false

# Don't accumulate snapshots from short-lived test deploys.
enable_snapshot_schedule = false

# Skip the managed SSL cert, HTTPS proxy, and HTTPS forwarding rule. The HTTP
# forwarding rule routes directly to the backend, so the deploy is reachable
# without setting up DNS for the test domain. Flip to `true` (or remove this
# line) when you have DNS pointing at the LB IP and want to validate TLS too.
enable_https = true

# ---- Optional Cloud DNS management ----------------------------------------
# DNS for quanbyit.com lives at GoDaddy, so we leave Terraform out of it.
# Set both lines if you ever move the test zone into Cloud DNS in this project.
# create_dns_record = true
# dns_managed_zone  = "quanbyit-com"

# ---- Optional: custom image PER VM ----------------------------------------
# Each VM independently chooses either a disk image (boot disk only) OR a
# machine image (whole VM incl. all attached disks). Set ONE per VM, not both.
#
# Disk image examples (overrides shared_image / ubuntu_image for that VM):
# prod_disk_image = "iacat-test/family/ppt-test-base"
# dr_disk_image   = "iacat-test/family/ppt-test-base"
#
# Machine image examples (full-VM snapshots from Console > Machine Images):
prod_machine_image = "projects/iacat-test/global/machineImages/prod-mi-with-disk"
dr_machine_image   = "projects/iacat-test/global/machineImages/dr-mi-with-disk"

# Let the machine image's captured values for machine_type, scheduling, and
# shielded_instance_config WIN over our vars. Network, IAM, firewall tags,
# and OS Login metadata always come from our config because they reference
# resources in THIS project. Default false = our vars override the MI.
prod_inherit_from_machine_image = true
dr_inherit_from_machine_image   = true

# When the machine image ALREADY carries the data disk baked in, set these
# to false. Skips: (a) creating google_compute_disk.{prod,dr}_data,
# (b) attaching it to the VM, (c) the snapshot policy binding, AND
# (d) running scripts/mount-data-disk-{prod,dr}.sh on every boot.
# Set true (default) when you need OUR separately-managed data disk
# (typical for the disk-image or default-Ubuntu paths).
prod_create_data_disk = false
dr_create_data_disk   = false
#
# CAUTION about machine images: they carry the source VM's data disk too. The
# separately-managed google_compute_disk.{prod_data,dr_data} resources still
# exist (snapshots keep working) but ARE NOT attached to the VM created from
# the MI -- the MI's restored data disk is what shows up at /data or /backups.
# Build the MI from a VM with the data disk DETACHED if you want the cleanest
# story (MI = boot only, our separate data disk attaches via the disk-image
# code path -- but then you wouldn't use the MI in the first place).
#
# shared_image still works as a both-VMs shortcut for the disk-image path:
# shared_image = "iacat-test/family/ppt-test-base"

# ---- Optional: skip the per-VM PROVISIONING script -------------------------
# Use ONLY together with a fully-baked shared_image. The data-disk mount
# script (scripts/mount-data-disk-{prod,dr}.sh) ALWAYS runs regardless --
# so /data and /backups are mounted on every boot either way. This switch
# only suppresses the install/config script in scripts/startup-{prod,dr}.sh.
# Useful in test to validate that your baked image really does include
# everything before you flip the same switch in production.
# run_startup_script = false
