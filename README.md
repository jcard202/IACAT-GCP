# ProtectPortal — GCP Hosting Infrastructure (Terraform)

Terraform configuration that provisions the **ProtectPortal Cloud Hosting Infrastructure** on Google Cloud (Singapore region, `asia-southeast1`).

This stack provisions:

- **Production VM** — 16 vCPU / 64 GB RAM, 50 GB SSD boot + 2 TB SSD data, Ubuntu 22.04 LTS, 24×7 with auto-restart.
- **DR VM** — 4 vCPU / 8 GB RAM, 50 GB SSD boot + 500 GB pd-standard data, Ubuntu 22.04 LTS.
- **Network** — custom VPC, two regional subnets, Cloud NAT, global LB IP.
- **Edge security** — Global HTTPS Load Balancer, Google-managed SSL, MODERN TLS policy (TLS 1.2/1.3), Cloud Armor WAF (OWASP CRS) with adaptive DDoS protection and per-IP rate limiting, HSTS.
- **Observability** — Ops Agent on each VM, Cloud Monitoring dashboard, alert policies (CPU / memory / disk / uptime / SSH brute force), log-based metrics, audit log sink to GCS.
- **Resilience** — daily snapshots of every persistent disk (30-day retention), Shielded VM, deletion protection.

---

## Documentation

| Doc | Purpose |
| --- | --- |
| [docs/PREREQUISITES.md](docs/PREREQUISITES.md) | **Start here.** Everything you need installed, configured, and authenticated before deploying. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | What gets built and the reasoning behind each choice. |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Step-by-step first-time deploy. |
| [docs/TESTING.md](docs/TESTING.md) | Step-by-step test run against the `iacat-test` sandbox project (~$0.06/hr). |
| [docs/TEST-RESET.md](docs/TEST-RESET.md) | Full teardown + rebuild procedure for the test env (handles `prevent_destroy`, the audit bucket, and the machine-image attached-disk dance). |
| [docs/PROD-RESET.md](docs/PROD-RESET.md) | ⚠️ Production teardown + rebuild. Pre-flight snapshot, DNS update for the new LB IP, cert re-validation, post-rebuild data restore from snapshot. |
| [docs/HTTPS-SETUP.md](docs/HTTPS-SETUP.md) | Enable Google-managed SSL on test (`iacat-test.quanbyit.com`) and prod (`iacat.quanbyit.com`) with GoDaddy DNS. |
| [docs/TERRAFORM-CHEATSHEET.md](docs/TERRAFORM-CHEATSHEET.md) | Commands, daily workflow, state management, and recovery patterns specific to this stack. |
| [docs/CUD-GUIDE.md](docs/CUD-GUIDE.md) | Buying, verifying, and renewing the production Committed Use Discount (~37%–55% off the VM bill). |
| [docs/SHARED-IMAGE-GUIDE.md](docs/SHARED-IMAGE-GUIDE.md) | Build a custom baked image and have both prod and DR boot from it (faster, identical baselines). |
| [docs/SPEC-VERIFICATION.md](docs/SPEC-VERIFICATION.md) | UAT checklist mapping every line of the procurement spec to a copy-pasteable verification command. |
| [docs/SPEC-VERIFICATION-CONSOLE.md](docs/SPEC-VERIFICATION-CONSOLE.md) | Same UAT checklist, but driven from the Cloud Console UI (no terminal) — easier to screenshot for the audit trail. |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2 ops — SSH, backups, DR drill, scaling, troubleshooting. |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, firewall posture, WAF rules, audit retention. |

---

## Repository layout

```
.
├── versions.tf                Terraform + provider versions and GCS backend stub
├── providers.tf               google / google-beta provider config + default labels
├── variables.tf               All input variables (project, sizing, CIDRs, domain)
├── locals.tf                  Common labels, computed values
├── terraform.tfvars.example   Copy → terraform.tfvars and fill in
├── network.tf                 VPC, subnets, Cloud Router/NAT, global LB IP
├── firewall.tf                IAP SSH, LB health check, internal prod↔DR, deny-all
├── iam.tf                     Per-VM service accounts and roles
├── compute.tf                 Prod + DR VMs, data disks, instance group, snapshot policy
├── lb.tf                      HTTPS LB + managed cert + SSL policy + Cloud Armor + HSTS
├── monitoring.tf              Alerts, uptime check, audit log sink, dashboard
├── outputs.tf                 IP addresses, names, IAP SSH commands
├── scripts/
│   ├── mount-data-disk-prod.sh  Prod data-disk mount (always runs, even when run_startup_script=false)
│   ├── mount-data-disk-dr.sh    DR data-disk mount (same — always runs)
│   ├── startup-prod.sh          Prod provisioning (PostgreSQL 16, nginx, ufw, SSH hardening)
│   └── startup-dr.sh            DR provisioning (PostgreSQL 16 server + client)
└── docs/                      Long-form documentation
```

---

## Prerequisites

In one line: Terraform `>= 1.6`, `gcloud` CLI authenticated, a billing-enabled GCP project, a domain you control, and an alert email.

Full step-by-step instructions — install commands, GCP project + billing setup, IAM roles, quotas, both required logins, and troubleshooting — are in **[docs/PREREQUISITES.md](docs/PREREQUISITES.md)**. Work through it once before doing anything else.

---

## Quick start

```bash
# 1. Authenticate
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID

# 2. Configure inputs
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set project_id, domain_name, alert_email

# 3. Initialize (with remote state)
terraform init \
  -backend-config="bucket=YOUR_TF_STATE_BUCKET" \
  -backend-config="prefix=protectportal/prod"

# 4. Review and apply
terraform plan
terraform apply

# 5. Point DNS at the load balancer
terraform output load_balancer_ip
# Create an A record:  portal.example.com  →  <that IP>
# Google-managed certs take 15–60 minutes to provision after DNS resolves.
```

---

## Required input variables

| Variable | Description | Example |
| --- | --- | --- |
| `project_id` | GCP project ID that will own the resources. | `protectportal-prod-123456` |
| `domain_name` | FQDN that resolves to the load balancer. | `portal.example.com` |
| `alert_email` | Address that receives Cloud Monitoring alerts. | `ops@example.com` |

All other variables have sensible defaults — see `variables.tf`.

---

## Outputs

| Output | Use |
| --- | --- |
| `load_balancer_ip` | Point your DNS A record at this. |
| `prod_external_ip` | Direct IP of the prod VM (bypasses the LB). |
| `prod_internal_ip` / `dr_internal_ip` | Private IPs for prod↔DR replication scripts. |
| `ssh_via_iap_prod` / `ssh_via_iap_dr` | Ready-to-paste `gcloud compute ssh` commands. |
| `audit_log_bucket` | GCS bucket holding exported audit logs. |

```bash
terraform output           # All outputs
terraform output -raw ssh_via_iap_prod | bash   # SSH to prod
```

---

## Costs (rough order of magnitude)

Singapore region, on-demand pricing, no committed-use discounts:

| Item | Approx monthly USD |
| --- | --- |
| Prod VM `n2-standard-16` | ~$700 |
| Prod data disk 2 TB pd-ssd | ~$340 |
| Prod boot disk 50 GB pd-ssd | ~$10 |
| DR VM `n2-custom-4-8192` | ~$95 |
| DR data disk 500 GB pd-standard | ~$25 |
| HTTPS LB + Cloud Armor | ~$30 baseline |
| Egress, snapshots, logs | variable |

Apply a 1- or 3-year **committed-use discount** on the production VM to cut ~30–50% off the compute line. See [docs/OPERATIONS.md](docs/OPERATIONS.md#cost-optimization).
