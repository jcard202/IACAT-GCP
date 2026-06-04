# ProtectPortal -- Production Architecture Report

**Project:** `protectportal-498318` *(PRODUCTION)*  
**Region:** `asia-southeast1`  
**Zones:** `asia-southeast1-a` (prod), `asia-southeast1-b` (DR)  
**Domain:** `iacat.quanbyit.com`  
**Generated:** 2026-06-04 06:52:16 +08:00

> This report describes WHAT is deployed and WHERE to find it in the Cloud Console. For pass/fail spec compliance verification, see `docs/SPEC-VERIFICATION.md` (manual) or run `scripts/validate-spec.ps1` (automated).

## 1. Architecture Overview

ProtectPortal runs on Google Cloud as a single-region, two-zone deployment.

| Layer | Components |
| --- | --- |
| Edge / Ingress | Global HTTPS Load Balancer with anycast IP, Cloud Armor WAF + DDoS protection, Google-managed SSL cert |
| Network | Custom VPC, prod + DR subnets in separate zones, Cloud NAT for private egress |
| Compute | Production VM (`protectportal-prod` in `asia-southeast1-a`) + DR VM (`protectportal-dr` in `asia-southeast1-b`), Shielded VM enabled on both |
| Storage | Persistent boot + data disks (`pd-ssd`/`pd-standard`), daily snapshot schedule, audit-log GCS bucket with WORM retention |
| Identity | Per-VM service accounts with least-privilege roles |
| Observability | Cloud Monitoring (custom dashboard, alert policies, uptime check), Cloud Logging (audit sink + log-based metrics) |

### Topology

```text
                         Internet (iacat.quanbyit.com)
                              |
                              v
              +-------------------------------+
              |  Global anycast IP            |  protectportal-lb-ip
              |  HTTPS Load Balancer          |
              +---------------+---------------+
                              |  port 443 (TLS 1.2/1.3 via MODERN policy)
                              |  port 80  -> 301 -> port 443
                              v
              +-------------------------------+
              |  Cloud Armor (WAF + DDoS)     |  protectportal-waf
              |  - OWASP CRS rules            |
              |  - Adaptive L7 protection     |
              |  - Per-IP rate limit          |
              +---------------+---------------+
                              |
                              v
              +-------------------------------+
              |  Backend service + HC         |  protectportal-backend
              |  HSTS + security headers      |
              +---------------+---------------+
                              |
                              v
    +---------------------------------------------------+
    |  VPC: protectportal-vpc                                  |
    |                                                   |
    |  +-----------------+      +-----------------+     |
    |  | prod-subnet     |      | dr-subnet       |     |
    |  | asia-southeast1-a   |      | asia-southeast1-b   |     |
    |  |                 |      |                 |     |
    |  |  protectportal-prod  |<---->|  protectportal-dr    |     |
    |  |  (live)         |      |  (DR)           |     |
    |  |  + 50GB boot    |      |  + 50GB boot    |     |
    |  |  + 2TB SSD data |      |  + 500GB data   |     |
    |  +-----------------+      +-----------------+     |
    |           \                       /               |
    |            +------ Cloud NAT -----+                |
    +---------------------------------------------------+
                              |
                              v
                  +-----------------------+
                  | Cloud Monitoring +    |
                  | Cloud Logging         |
                  | + audit -> GCS bucket |
                  +-----------------------+
```

## 2. Component Inventory

Every resource the Terraform stack created in production, grouped by category. The right column is the Cloud Console navigation path the reviewer follows from the left-side menu.

> **Before navigating:** open `https://console.cloud.google.com`, then select project `protectportal-498318` from the top-bar project picker. All paths assume this is done.

### Compute / Disk

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-prod` | 12	pd-ssd	READY | `Compute Engine -> Disks -> protectportal-prod` |
| `protectportal-prod-data` | -- | `Compute Engine -> Disks -> protectportal-prod-data` |
| `protectportal-dr` | 13	pd-ssd	READY | `Compute Engine -> Disks -> protectportal-dr` |
| `protectportal-dr-data` | -- | `Compute Engine -> Disks -> protectportal-dr-data` |

### Compute / VM

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-prod` | e2-medium	RUNNING	10.20.0.2	production | `Compute Engine -> VM instances -> protectportal-prod` |
| `protectportal-dr` | e2-micro	RUNNING	10.20.1.2	disaster-recovery | `Compute Engine -> VM instances -> protectportal-dr` |

### IAM / Service Account

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `terraform@protectportal-498318.iam.gserviceaccount.com` | terraform | `IAM & Admin -> Service Accounts -> terraform@protectportal-498318.iam.gserviceaccount.com` |
| `protectportal-prod-vm@protectportal-498318.iam.gserviceaccount.com` | ProtectPortal Production VM | `IAM & Admin -> Service Accounts -> protectportal-prod-vm@protectportal-498318.iam.gserviceaccount.com` |
| `protectportal-dr-vm@protectportal-498318.iam.gserviceaccount.com` | ProtectPortal DR VM | `IAM & Admin -> Service Accounts -> protectportal-dr-vm@protectportal-498318.iam.gserviceaccount.com` |

### Load balancer / Backend service

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-backend` | Health: HEALTHY | `Network services -> Load balancing -> Backend services -> protectportal-backend` |

### Load balancer / Cloud Armor (WAF)

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-waf` | CLOUD_ARMOR	True, 8 rules | `Network security -> Cloud Armor policies -> protectportal-waf` |

### Load balancer / Forwarding rule

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-http-fr` | 80-80 @ 8.232.219.109 (EXTERNAL_MANAGED) | `Network services -> Load balancing -> Frontends -> protectportal-http-fr` |
| `protectportal-https-fr` | 443-443 @ 8.232.219.109 (EXTERNAL_MANAGED) | `Network services -> Load balancing -> Frontends -> protectportal-https-fr` |

### Load balancer / Global IP

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-lb-ip` | 8.232.219.109	IN_USE	EXTERNAL | `VPC network -> IP addresses -> protectportal-lb-ip` |

### Load balancer / Health check

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-http-hc` | HTTP | `Compute Engine -> Health checks -> protectportal-http-hc` |

### Load balancer / HTTP proxy

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-http-proxy` | url-map: protectportal-http-redirect (redirect to HTTPS) | `Network services -> Load balancing -> [LB name] -> Frontend (HTTP)` |

### Load balancer / HTTPS proxy

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-https-proxy` | uses cert: protectportal-managed-cert | `Network services -> Load balancing -> [LB name] -> Frontend (HTTPS)` |

### Load balancer / Instance group

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-prod-ig` | 1 instance(s) in asia-southeast1-a | `Compute Engine -> Instance groups -> protectportal-prod-ig` |

### Load balancer / SSL certificate (managed)

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-managed-cert` | protectportal-managed-cert	ACTIVE	iacat.quanbyit.com=ACTIVE	iacat.quanbyit.com | `Network services -> Load balancing -> [LB name] -> Frontend -> Certificate` |

### Load balancer / SSL policy

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-ssl-policy` | Profile: MODERN	TLS_1_2 | `Network services -> Load balancing -> SSL policies -> protectportal-ssl-policy` |

### Load balancer / URL map

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-http-redirect` | default -> | `Network services -> Load balancing -> [LB name] -> Host and path rules` |
| `protectportal-urlmap` | default -> protectportal-backend | `Network services -> Load balancing -> [LB name] -> Host and path rules` |

### Logging / Log-based metric

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal/failed_ssh_attempts` | Counts matches into Cloud Monitoring | `Logging -> Log-based Metrics -> protectportal/failed_ssh_attempts` |

### Logging / Sink

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-audit-sink` | -> storage.googleapis.com/protectportal-498318-protectportal-audit-691f4d3e | `Logging -> Log Router -> protectportal-audit-sink` |

### Monitoring / Alert policy

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal suspected SSH brute force` | Enabled: True | `Monitoring -> Alerting -> Policies -> protectportal suspected SSH brute force` |
| `protectportal-prod memory > 90%` | Enabled: True | `Monitoring -> Alerting -> Policies -> protectportal-prod memory > 90%` |
| `protectportal-prod disk > 85%` | Enabled: True | `Monitoring -> Alerting -> Policies -> protectportal-prod disk > 85%` |
| `protectportal-prod CPU > 85%` | Enabled: True | `Monitoring -> Alerting -> Policies -> protectportal-prod CPU > 85%` |
| `protectportal HTTPS uptime failed` | Enabled: True | `Monitoring -> Alerting -> Policies -> protectportal HTTPS uptime failed` |

### Monitoring / Dashboard

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal Overview` | Custom overview dashboard | `Monitoring -> Dashboards -> protectportal Overview` |

### Monitoring / Notification channel

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal ops email` | email () | `Monitoring -> Alerting -> Edit Notification Channels` |

### Monitoring / Uptime check

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-https-uptime` | Polls iacat.quanbyit.com every 60s | `Monitoring -> Uptime checks -> protectportal-https-uptime` |

### Network / Cloud NAT

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-nat` | AUTO_ONLY / ALL_SUBNETWORKS_ALL_IP_RANGES | `Network services -> Cloud NAT -> protectportal-nat` |

### Network / Cloud Router

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-router` | in asia-southeast1 | `Network connectivity -> Cloud Router -> protectportal-router` |

### Network / Firewall rule

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-allow-iap-ssh` | INGRESS priority 1000 (src: 35.235.240.0/20) | `VPC network -> Firewall -> protectportal-allow-iap-ssh` |
| `protectportal-allow-internal` | INGRESS priority 1000 (tag-based) | `VPC network -> Firewall -> protectportal-allow-internal` |
| `protectportal-allow-lb-hc` | INGRESS priority 1000 (src: 130.211.0.0/22;35.191.0.0/16) | `VPC network -> Firewall -> protectportal-allow-lb-hc` |
| `protectportal-deny-all-ingress` | INGRESS priority 65534 (src: 0.0.0.0/0) | `VPC network -> Firewall -> protectportal-deny-all-ingress` |

### Network / Subnet

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-dr-subnet` | 10.20.1.0/24 in asia-southeast1 | `VPC network -> Subnets -> protectportal-dr-subnet` |
| `protectportal-prod-subnet` | 10.20.0.0/24 in asia-southeast1 | `VPC network -> Subnets -> protectportal-prod-subnet` |

### Network / VPC

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-vpc` | ,  routing | `VPC network -> VPC networks -> protectportal-vpc` |

### Storage / Bucket

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-498318-protectportal-audit-691f4d3e` | in ASIA-SOUTHEAST1 | `Cloud Storage -> Buckets -> protectportal-498318-protectportal-audit-691f4d3e` |
| `protectportal-498318-tfstate` | in ASIA-SOUTHEAST1 | `Cloud Storage -> Buckets -> protectportal-498318-tfstate` |

### Storage / Snapshot schedule

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-daily-snapshot` | Daily snapshot policy | `Compute Engine -> Snapshots -> Snapshot schedules -> protectportal-daily-snapshot` |

## 3. Cloud Console Navigation Guide

Master list of where every category of component lives in the Console. Use the project picker to select `protectportal-498318` first.

### Compute Engine

| What you want to see | Navigation path |
| --- | --- |
| All VMs | `Compute Engine -> VM instances` |
| One specific VM | `Compute Engine -> VM instances -> <vm-name>` (machine type, network interfaces, scheduling, Shielded VM config, etc.) |
| VM serial console | `Compute Engine -> VM instances -> <vm-name> -> Serial port output` (disabled in this deploy for security) |
| All disks | `Compute Engine -> Disks` |
| Specific disk | `Compute Engine -> Disks -> <disk-name>` |
| Snapshots | `Compute Engine -> Snapshots` |
| Snapshot schedules | `Compute Engine -> Snapshots -> Snapshot schedules` |
| Instance groups (for LB) | `Compute Engine -> Instance groups` |
| Health checks | `Compute Engine -> Health checks` |
| Machine images | `Compute Engine -> Machine images` |
| Custom (disk) images | `Compute Engine -> Images`, switch to 'Custom images' tab |

### VPC Network

| What you want to see | Navigation path |
| --- | --- |
| All VPCs | `VPC network -> VPC networks` |
| Specific VPC details | `VPC network -> VPC networks -> <vpc-name>` |
| Subnets | `VPC network -> Subnets` |
| Firewall rules | `VPC network -> Firewall` |
| External / static IPs | `VPC network -> IP addresses` |
| Routes (incl. NAT route) | `VPC network -> Routes` |
| VPC Flow Logs | enable in `VPC network -> Subnets -> <subnet> -> Edit -> Flow logs` |

### Network Services / Load Balancing

| What you want to see | Navigation path |
| --- | --- |
| All load balancers | `Network services -> Load balancing` |
| LB front-end / IPs / certs | `Network services -> Load balancing -> <LB name> -> Frontend` |
| LB backend health | `Network services -> Load balancing -> Backend services -> protectportal-backend` |
| URL maps / routing | `Network services -> Load balancing -> [LB name] -> Host and path rules` |
| Forwarding rules | `Network services -> Load balancing -> Frontends` |
| SSL policies | `Network services -> Load balancing -> SSL policies` |
| Cloud NAT | `Network services -> Cloud NAT` |

### Network Security

| What you want to see | Navigation path |
| --- | --- |
| Cloud Armor WAF policy | `Network security -> Cloud Armor policies -> protectportal-waf` |
| Adaptive Protection findings | `Network security -> Cloud Armor -> Adaptive Protection` |
| Certificate Manager (managed certs) | `Network security -> Certificate Manager -> Classic certificates` |

### IAM & Admin

| What you want to see | Navigation path |
| --- | --- |
| Project-level IAM bindings | `IAM & Admin -> IAM` |
| Service accounts | `IAM & Admin -> Service Accounts` |
| SA's own permissions tab (tokenCreator etc.) | `IAM & Admin -> Service Accounts -> <SA email> -> Permissions` |
| Quotas | `IAM & Admin -> Quotas` (filter by Compute Engine API + Region) |
| Audit logs configuration | `IAM & Admin -> Audit Logs` |

### Monitoring

| What you want to see | Navigation path |
| --- | --- |
| Custom dashboard | `Monitoring -> Dashboards` -> open 'protectportal Overview' |
| Alert policies | `Monitoring -> Alerting -> Policies` |
| Uptime checks | `Monitoring -> Uptime checks` |
| Notification channels | `Monitoring -> Alerting -> Edit Notification Channels` |
| Metric explorer (ad-hoc queries) | `Monitoring -> Metrics explorer` |

### Logging

| What you want to see | Navigation path |
| --- | --- |
| Logs Explorer (ad-hoc queries) | `Logging -> Logs Explorer` |
| Log sinks (audit export) | `Logging -> Log Router` |
| Log-based metrics | `Logging -> Log-based Metrics` |
| Log storage / retention | `Logging -> Log Storage` |

### Cloud Storage

| What you want to see | Navigation path |
| --- | --- |
| All buckets | `Cloud Storage -> Buckets` |
| Bucket details (retention / versioning / IAM) | `Cloud Storage -> Buckets -> <bucket-name> -> Configuration` |
| Bucket objects | `Cloud Storage -> Buckets -> <bucket-name> -> Objects` |

### Billing & Cost

| What you want to see | Navigation path |
| --- | --- |
| Project billing link | `Billing` -> 'Account management' (if you have access) |
| Cost breakdown by SKU | `Billing -> Reports` (filter by project = `protectportal-498318`) |
| Committed Use Discounts | `Compute Engine -> Committed use discounts` |
| Cost optimization recommendations | `Billing -> Cost optimization recommendations` |

## 4. Document References

- `docs/SPEC-VERIFICATION.md` -- Manual line-by-line spec checks with gcloud commands and expected output
- `docs/SPEC-VERIFICATION-CONSOLE.md` -- Same checks driven entirely from Cloud Console clicks
- `docs/ARCHITECTURE.md` -- Detailed design notes + topology diagram
- `docs/SECURITY.md` -- Spec-to-control mapping, IAM model, audit trail
- `docs/OPERATIONS.md` -- Day-2 procedures (SSH, snapshots, DR drill, scaling, log queries)
- `docs/PROD-RESET.md` -- Production teardown + rebuild procedure
- `docs/TERRAFORM-CHEATSHEET.md` -- Common Terraform commands for this stack
- `scripts/validate-spec.ps1` -- Automated PASS/FAIL spec validation report

---

Generated by `scripts/prod-architecture-report.ps1`.

