# ProtectPortal -- Production Architecture Report

**Project:** `protectportal-498318` *(PRODUCTION)*  
**Region:** `asia-southeast1`  
**Zones:** `asia-southeast1-a` (prod), `asia-southeast1-b` (DR)  
**Domain:** `iacat.quanbyit.com`  
**Generated:** 2026-06-04 06:48:22 +08:00

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
| `protectportal-prod` | -- | `Compute Engine -> Disks -> protectportal-prod` |
| `protectportal-prod-data` | -- | `Compute Engine -> Disks -> protectportal-prod-data` |
| `protectportal-dr` | -- | `Compute Engine -> Disks -> protectportal-dr` |
| `protectportal-dr-data` | -- | `Compute Engine -> Disks -> protectportal-dr-data` |

### Compute / VM

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-prod` | -- | `Compute Engine -> VM instances -> protectportal-prod` |
| `protectportal-dr` | -- | `Compute Engine -> VM instances -> protectportal-dr` |

### Load balancer / Backend service

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-backend` | Health: | `Network services -> Load balancing -> Backend services -> protectportal-backend` |

### Load balancer / Cloud Armor (WAF)

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-waf` | , 1 rules | `Network security -> Cloud Armor policies -> protectportal-waf` |

### Load balancer / Global IP

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-lb-ip` | -- | `VPC network -> IP addresses -> protectportal-lb-ip` |

### Load balancer / SSL certificate (managed)

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-managed-cert` | -- | `Network services -> Load balancing -> [LB name] -> Frontend -> Certificate` |

### Load balancer / SSL policy

| Name | Configuration | Cloud Console navigation |
| --- | --- | --- |
| `protectportal-ssl-policy` | Profile: | `Network services -> Load balancing -> SSL policies -> protectportal-ssl-policy` |

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

