###############################################################################
# Project / location
###############################################################################

variable "project_id" {
  description = "GCP project ID that owns the ProtectPortal infrastructure."
  type        = string
}

variable "region" {
  description = "Primary GCP region. Singapore by default."
  type        = string
  default     = "asia-southeast1"
}

variable "prod_zone" {
  description = "Zone for the production VM."
  type        = string
  default     = "asia-southeast1-a"
}

variable "dr_zone" {
  description = "Zone for the DR VM. Distinct from prod_zone for zone-level isolation."
  type        = string
  default     = "asia-southeast1-b"
}

###############################################################################
# Naming / labels
###############################################################################

variable "name_prefix" {
  description = "Prefix for resource names (lowercase, alphanumeric, dashes)."
  type        = string
  default     = "protectportal"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-21 chars, lowercase letters/digits/dashes, starting with a letter."
  }
}

variable "environment" {
  description = "Environment label applied to all resources (e.g. prod, staging)."
  type        = string
  default     = "prod"
}

variable "cost_center" {
  description = "Cost center label for billing chargeback / FinOps."
  type        = string
  default     = "protectportal"
}

variable "owner" {
  description = "Team or individual responsible for this stack (label only)."
  type        = string
  default     = "platform"
}

###############################################################################
# Network
###############################################################################

variable "vpc_cidr_prod" {
  description = "CIDR for the production subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "vpc_cidr_dr" {
  description = "CIDR for the DR subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "ssh_source_ranges" {
  description = "CIDRs allowed to SSH via the IAP tunnel-allow rule. Leave the default to force SSH-via-IAP only."
  type        = list(string)
  default     = ["35.235.240.0/20"] # Google IAP range
}

###############################################################################
# Compute — Production
###############################################################################

variable "prod_machine_type" {
  description = "Machine type for the production VM. n2-standard-16 = 16 vCPU / 64 GB."
  type        = string
  default     = "n2-standard-16"
}

variable "prod_boot_disk_size_gb" {
  description = "Boot disk size for the production VM (GB)."
  type        = number
  default     = 50
}

variable "prod_data_disk_size_gb" {
  description = "Data disk size for the production VM (GB). 2 TB by spec."
  type        = number
  default     = 2048
}

variable "prod_data_disk_type" {
  description = "Persistent disk type for production data disk. pd-ssd is recommended for the live DB."
  type        = string
  default     = "pd-ssd"
}

variable "prod_boot_disk_type" {
  description = "Boot disk type for the production VM."
  type        = string
  default     = "pd-ssd"
}

###############################################################################
# Compute — DR
###############################################################################

variable "dr_machine_type" {
  description = "Machine type for the DR VM. n2-custom-4-8192 = 4 vCPU / 8 GB."
  type        = string
  default     = "n2-custom-4-8192"
}

variable "dr_boot_disk_size_gb" {
  description = "Boot disk size for the DR VM (GB)."
  type        = number
  default     = 50
}

variable "dr_data_disk_size_gb" {
  description = "Data disk size for the DR VM (GB). 500 GB by spec."
  type        = number
  default     = 500
}

variable "dr_data_disk_type" {
  description = "Persistent disk type for DR data disk. pd-standard per spec (HDD)."
  type        = string
  default     = "pd-standard"
}

variable "dr_boot_disk_type" {
  description = "Boot disk type for the DR VM."
  type        = string
  default     = "pd-ssd"
}

###############################################################################
# OS image
###############################################################################

variable "ubuntu_image" {
  description = "Source image family/family-project used when shared_image is empty. Ubuntu 22.04 LTS by default."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "shared_image" {
  description = "Optional disk image used by BOTH prod and DR VM boot disks (shortcut for setting prod_disk_image + dr_disk_image to the same value). Format: '<project>/<image-name>' or '<project>/family/<family>'. Overridden by per-VM prod_disk_image / dr_disk_image if those are set. Leave empty to use var.ubuntu_image."
  type        = string
  default     = ""
}

# Per-VM image overrides. Each VM picks ONE of disk image or machine image:
#  - Disk image: source for the boot disk only. Data disks are still attached
#    separately via google_compute_disk resources. Recommended for our
#    architecture because the data-disk lifecycle is independent.
#  - Machine image: snapshot of the entire VM (boot + attached disks + metadata).
#    When set, source_machine_image is used; boot_disk config is taken from the
#    machine image. CAUTION: machine images include the source VM's data disk;
#    build from a VM with the data disk DETACHED to avoid getting two data
#    disks attached after restore.

variable "prod_disk_image" {
  description = "Optional disk image for the prod VM boot disk. Format: '<project>/<image-name>' or '<project>/family/<family>'. Overrides shared_image / ubuntu_image. Mutually exclusive with prod_machine_image."
  type        = string
  default     = ""
}

variable "prod_machine_image" {
  description = "Optional machine image to create the prod VM from. Format: 'projects/<project>/global/machineImages/<name>'. Mutually exclusive with prod_disk_image. See note above about data disks."
  type        = string
  default     = ""
}

variable "dr_disk_image" {
  description = "Optional disk image for the DR VM boot disk. Same semantics as prod_disk_image but for DR."
  type        = string
  default     = ""
}

variable "dr_machine_image" {
  description = "Optional machine image to create the DR VM from. Same semantics as prod_machine_image but for DR."
  type        = string
  default     = ""
}

variable "prod_inherit_from_machine_image" {
  description = "Only meaningful with prod_machine_image set. When true, the MI's captured values for machine_type, scheduling, and shielded_instance_config WIN over our vars / defaults. Network, IAM SA, firewall tags, and OS Login metadata are still overridden because they reference project-specific resources. Default false: our vars override the MI."
  type        = bool
  default     = false
}

variable "dr_inherit_from_machine_image" {
  description = "Same as prod_inherit_from_machine_image but for the DR VM."
  type        = bool
  default     = false
}

variable "prod_create_data_disk" {
  description = "When true (default), Terraform creates google_compute_disk.prod_data, attaches it to the prod VM as device 'protectportal-prod-data' at /data, and runs mount-data-disk-prod.sh on every boot. Set to false when prod_machine_image already includes the data disk baked in -- avoids the device_name collision and the unused disk. With this off, the MI is responsible for mounting whatever data disk it carries."
  type        = bool
  default     = true
}

variable "dr_create_data_disk" {
  description = "Same as prod_create_data_disk but for the DR VM."
  type        = bool
  default     = true
}

variable "run_startup_script" {
  description = "When true (default), the per-VM provisioning script in scripts/startup-{prod,dr}.sh runs on first boot to install packages (PostgreSQL, nginx, etc.), configure ufw, harden SSH, and set up the PostgreSQL cluster. Set to false when the shared_image already includes everything -- typical for a fully-baked golden image. The data-disk mount script (scripts/mount-data-disk-{prod,dr}.sh) runs in all cases regardless of this flag, so /data and /backups are always ready."
  type        = bool
  default     = true
}

###############################################################################
# Public ingress / SSL
###############################################################################

variable "domain_name" {
  description = "FQDN that resolves to the load balancer (used for the managed SSL cert). Required when enable_https = true."
  type        = string
  default     = ""
}

variable "enable_https" {
  description = "When false, skips the managed SSL cert, HTTPS proxy, HTTPS forwarding rule, and the HTTP->HTTPS redirect. The HTTP forwarding rule then points at the backend directly. Useful for test deploys where DNS isn't available."
  type        = bool
  default     = true
}

variable "create_dns_record" {
  description = "If true, manage the A record in Cloud DNS. Requires dns_managed_zone."
  type        = bool
  default     = false
}

variable "dns_managed_zone" {
  description = "Name of an existing Cloud DNS managed zone. Required only when create_dns_record = true."
  type        = string
  default     = ""
}

###############################################################################
# Test / cost knobs
###############################################################################

variable "enable_deletion_protection" {
  description = "Turn off for throwaway test environments so `terraform destroy` works cleanly."
  type        = bool
  default     = true
}

variable "enable_snapshot_schedule" {
  description = "Attach the daily snapshot policy to data disks. Turn off for short-lived test deploys."
  type        = bool
  default     = true
}

variable "enable_backup_dr" {
  description = "Enable GCP Backup & DR Service: creates a regional backup vault, a daily backup plan, and plan associations for prod + DR VMs. Provides VM-level (not just disk) protection, immutable retention, and a centralised backup catalogue. Required for compliance-grade audit. Adds ~$50/mo per protected VM in vault storage + management fees. Requires backupdr.googleapis.com API enabled at the project level."
  type        = bool
  default     = true
}

variable "backup_dr_retention_days" {
  description = "Days to keep each Backup & DR Service backup. Independent of the disk-snapshot retention. The vault enforces a MINIMUM retention duration of this value -- backups cannot be deleted earlier even by an admin, providing ransomware/insider-threat protection."
  type        = number
  default     = 30
}

variable "backup_dr_window_start_hour_utc" {
  description = "Hour of day (UTC, 0-23) when the daily backup window opens. Default 17 UTC = 01:00 SGT (UTC+8)."
  type        = number
  default     = 17
}

###############################################################################
# Monitoring
###############################################################################

variable "alert_email" {
  description = "Email address that receives Cloud Monitoring alerts."
  type        = string
}
