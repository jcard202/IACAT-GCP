# Architecture

## Topology

```
                         Internet
                            │
                            ▼
              ┌─────────────────────────────┐
              │  Global Anycast IP          │   google_compute_global_address.lb_ip
              │  (HTTPS Load Balancer)      │
              └──────────────┬──────────────┘
                             │   :443 (TLS 1.2/1.3, MODERN policy)
                             │   :80  → 301 → :443
                             ▼
              ┌─────────────────────────────┐
              │  Cloud Armor (WAF + DDoS)   │   google_compute_security_policy.waf
              │  • OWASP CRS rules          │
              │  • Adaptive L7 DDoS         │
              │  • 600 req/min/IP rate-ban  │
              └──────────────┬──────────────┘
                             │
                             ▼
              ┌─────────────────────────────┐
              │  Backend service + HC       │   google_compute_backend_service.portal
              │  + HSTS / security headers  │
              └──────────────┬──────────────┘
                             │
       ┌─────────────────────┴────────────────────────┐
       │ VPC: protectportal-vpc                       │
       │                                              │
       │  ┌──────────────────┐    ┌─────────────────┐ │
       │  │ prod-subnet      │    │ dr-subnet       │ │
       │  │ 10.20.0.0/24     │    │ 10.20.1.0/24    │ │
       │  │ zone -a          │    │ zone -b         │ │
       │  │                  │    │                 │ │
       │  │ ┌──────────────┐ │    │ ┌─────────────┐ │ │
       │  │ │ Prod VM      │ │    │ │ DR VM       │ │ │
       │  │ │ n2-std-16    │ │◄──►│ │ n2-cust-4-  │ │ │
       │  │ │ 64 GB RAM    │ │    │ │ 8192        │ │ │
       │  │ │ 50 GB boot   │ │    │ │ 50 GB boot  │ │ │
       │  │ │ 2 TB data    │ │    │ │ 500 GB data │ │ │
       │  │ │ public IP    │ │    │ │ no pub IP   │ │ │
       │  │ └──────┬───────┘ │    │ └──────┬──────┘ │ │
       │  └─────────┼────────┘    └────────┼────────┘ │
       │           │                       │          │
       │           └───── Cloud NAT ───────┘          │
       │                                              │
       └──────────────────────────────────────────────┘
                             │
        ┌────────────────────┴──────────────────────┐
        │                                           │
        ▼                                           ▼
  ┌──────────────┐                       ┌────────────────────┐
  │ Cloud Logging│                       │ Cloud Monitoring   │
  │   ↓ sink     │                       │ • Dashboards       │
  │ GCS audit    │                       │ • Alerts → email   │
  │ bucket (WORM)│                       │ • Uptime checks    │
  └──────────────┘                       └────────────────────┘
```

## Components

### Network (`network.tf`)

- **Custom VPC** — `auto_create_subnetworks = false`. No default network means no implicit public exposure.
- **Two subnets** in `asia-southeast1`, each in a different zone so a single-zone outage cannot take down both VMs.
- **VPC Flow Logs** enabled at 50% sampling on both subnets for forensic and capacity-planning use.
- **Cloud Router + Cloud NAT** provides egress for the DR VM (which has no public IP) and for any future private workloads.
- **Reserved global IP** for the load balancer so the address survives LB re-creation.

### Firewall (`firewall.tf`)

Deny-by-default. Only explicit ingress rules allow traffic:

| Rule | Source | Target tag | Ports |
| --- | --- | --- | --- |
| IAP SSH | `35.235.240.0/20` | `ssh-iap` | 22/tcp |
| LB health checks | `130.211.0.0/22`, `35.191.0.0/16` | `http-backend` | 80, 443/tcp |
| Internal prod↔DR | tag `protectportal-prod` / `protectportal-dr` | same | 22, 5432, icmp |
| Deny-all logging rule | `0.0.0.0/0` | any | all (logs and drops) |

### IAM (`iam.tf`)

Each VM runs as its **own dedicated service account** with the minimum roles needed for the Ops Agent and Artifact Registry:

- `roles/logging.logWriter`
- `roles/monitoring.metricWriter`
- `roles/monitoring.viewer`
- `roles/stackdriver.resourceMetadata.writer`
- `roles/artifactregistry.reader`

No project owner/editor roles on VMs.

### Compute (`compute.tf`)

| | Production | DR |
| --- | --- | --- |
| Machine type | `n2-standard-16` (16 vCPU / 64 GB) | `n2-custom-4-8192` (4 vCPU / 8 GB) |
| Zone | `asia-southeast1-a` | `asia-southeast1-b` |
| Boot disk | 50 GB `pd-ssd` | 50 GB `pd-ssd` |
| Data disk | 2 TB `pd-ssd` (mounted at `/data`) | 500 GB `pd-standard` (mounted at `/backups`) |
| Public IP | yes (temporary; remove after LB cutover) | no |
| Service account | `protectportal-prod-vm` | `protectportal-dr-vm` |
| Shielded VM | secure boot + vTPM + integrity monitoring | same |
| Auto-restart | yes | yes |
| Live migration | yes (`MIGRATE` on host maintenance) | yes |
| Deletion protection | yes | yes |
| OS Login | enforced (`enable-oslogin = TRUE`) | enforced |
| Project SSH keys | blocked | blocked |
| Serial port | disabled | disabled |

Data disks are **separate `google_compute_disk` resources** with `prevent_destroy = true`. The VM can be recreated without losing the data disk.

Backup is layered:

- **Backup & DR Service** (managed by `backup-dr.tf`, gated on `var.enable_backup_dr`) — regional **backup vault** with WORM-enforced minimum retention, a **daily backup plan** at the VM level (application-consistent, not just disk-snapshot), and a **plan association** per VM. Backups are immutable until the vault's enforced retention expires — even Owner cannot delete them early, which gives ransomware/insider-threat protection. Cost: ~$50/mo per protected VM in vault storage. Required for compliance audits.
- **Disk snapshot policy** (managed by `compute.tf`, gated on `var.enable_snapshot_schedule`) — daily resource-policy attached to both data disks at the PD level: 01:00 SGT window, 30-day retention, snapshots survive disk deletion. Cheaper but disk-level only (no application consistency); kept as a belt-and-suspenders second tier.

### Load balancer & edge security (`lb.tf`)

- **Global External Application Load Balancer** (`EXTERNAL_MANAGED`). Single anycast IP, ~150 ms global response.
- **Google-managed SSL certificate** for `var.domain_name`. Auto-renews; takes 15–60 minutes to validate after DNS resolves.
- **SSL policy** — `MODERN` profile, `min_tls_version = TLS_1_2`. Negotiates TLS 1.3 with modern clients.
- **Cloud Armor security policy** attached to the backend:
  - OWASP Core Rule Set (SQLi, XSS, LFI, RFI, RCE, scanner detection)
  - Adaptive Protection (machine-learning L7 DDoS defence)
  - Rate-based ban: 600 requests / 60 s / source IP → 5-minute ban on exceed
- **Security response headers** injected at the LB (`custom_response_headers`):
  - `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: strict-origin-when-cross-origin`
- **HTTP → HTTPS redirect** on port 80 via a separate `url_map` with `default_url_redirect`.

### Monitoring (`monitoring.tf`)

- **Email notification channel** for `var.alert_email`.
- **Uptime check** — HTTPS GET `/` every 60 s, SSL validation enabled.
- **Alert policies**:
  - Prod CPU > 85% for 5 min
  - Prod memory > 90% for 5 min
  - Prod disk > 85% for 10 min
  - Uptime check failed
  - Failed SSH attempts > 20 / 5 min (brute-force detector)
- **Log-based metric** counting `Failed password` and `Invalid user` in syslog/auth.
- **Audit log sink** → versioned GCS bucket with 1-day WORM retention and 400-day lifecycle delete. Captures `cloudaudit.googleapis.com` plus compute, IAM, and KMS service events.
- **Custom dashboard** — CPU / memory / disk / network for prod, CPU for DR, LB request rate.

### Bootstrap scripts (`scripts/`)

Each VM's `metadata_startup_script` is built by `compute.tf` from **two** files concatenated:

1. **`mount-data-disk-{prod,dr}.sh`** — always runs (regardless of `var.run_startup_script`). Formats the data disk if blank, mounts it at `/data` or `/backups`, and pins an fstab entry by UUID. Writes its log to `/var/log/protectportal-mount.log`. Idempotent.
2. **`startup-{prod,dr}.sh`** — runs only when `var.run_startup_script = true` (the default). Handles full provisioning: packages, ufw, SSH hardening, PostgreSQL install + cluster relocation. Writes to `/var/log/protectportal-startup.log`. Idempotent.

The split lets you skip step 2 when using a fully-baked `shared_image` (golden image with everything pre-installed), while still guaranteeing the data disk gets mounted — because the data disk is a separate `google_compute_disk` resource that's never inside any image.

`startup-prod.sh` installs:
- Google Cloud Ops Agent
- nginx with HSTS / security-header config
- certbot (for fallback Let's Encrypt — the managed cert is the primary)
- fail2ban
- unattended-upgrades
- **PostgreSQL 16** from PGDG, cluster relocated to `/data/postgres/16/main` on the 2 TB SSD
- `listen_addresses = '*'` with `pg_hba.conf` allowing `scram-sha-256` from the DR subnet (CIDR read from VM metadata `db-allow-cidr`, sourced from `var.vpc_cidr_dr`)
- Mounts the 2 TB data disk at `/data` (formatted ext4 if blank)
- Hardens SSH (`PasswordAuthentication no`, `PermitRootLogin no`)
- Enables ufw allowing 22/80/443 and 5432 from the DR CIDR only

`startup-dr.sh` installs:
- Ops Agent
- PostgreSQL 16 server + client (for restoring nightly dumps to validate them)
- Cluster data directory at `/backups/postgres/16/main` on the 500 GB data disk
- Listens on `localhost` only — no inbound connections
- Mounts the 500 GB data disk at `/backups`

## Design decisions

### Why a custom VPC instead of the default?

The default network has overly permissive firewall rules (ICMP/RDP/SSH from anywhere) and uses auto-mode subnets. A custom VPC starts deny-by-default and lets us pin CIDRs to known ranges for routing predictability.

### Why `pd-ssd` for the 2 TB data disk when the spec said "Standard SSD"?

GCP doesn't have a product literally called "Standard SSD". Closest options:
- `pd-ssd` — high-performance SSD (~3 IOPS/GB baseline, scales with size)
- `pd-balanced` — cost-optimized SSD (~6 IOPS/GB baseline, lower throughput ceiling)

For a live database disk, `pd-ssd` is the safer interpretation. Override with `prod_data_disk_type = "pd-balanced"` to cut ~40% off the disk bill if your workload is read-light.

### Why MODERN SSL policy instead of RESTRICTED?

`RESTRICTED` only allows TLS 1.2+ with a tight cipher list — it breaks older clients (older Android, some embedded devices). `MODERN` enforces TLS 1.2+ and prefers TLS 1.3 but allows a slightly broader cipher list. Switch to `RESTRICTED` if you need PCI-DSS evidence of strong-ciphers-only.

### Why is the prod VM behind an LB **and** has a public IP?

For initial bootstrap and operator convenience. The LB depends on a healthy backend, so during first deploy you need direct access to install your app before the LB will pass health checks. Remove the `access_config` block in `compute.tf` after cutover and re-apply — all traffic then flows through Cloud Armor.

### Why a separate DR VM rather than HA replication?

The spec called for daily SQL dumps with restore validation, not synchronous replication. A small DR VM in a different zone is cheaper than a Cloud SQL HA pair and matches the stated RPO (24 h) / RTO (manual restore) requirements. If RPO < 1 h is later required, migrate to managed Cloud SQL with HA.

### Why are startup scripts marked `ignore_changes`?

`metadata_startup_script` only runs on first boot. Editing it after the VM exists has no runtime effect — but Terraform would still show a perpetual diff. `ignore_changes` keeps plans clean. To apply script changes to a running instance, copy the new script up and run it manually, or recreate the VM with `terraform taint`.
