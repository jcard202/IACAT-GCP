# Specification Verification — Google Cloud Console Edition

The same line-by-line acceptance test as [SPEC-VERIFICATION.md](SPEC-VERIFICATION.md), but driven entirely from the **Cloud Console UI**. Use this when the auditor / signer prefers point-and-click over a terminal, or when capturing screenshots for the procurement record.

Each check has:
1. The spec text being verified.
2. A direct deep-link URL to the right Console page.
3. What to click and what to look for.
4. What a passing result looks like (so you can screenshot it).

> **Convention**: URLs and resource names use `iacat-prod` / `protectportal-*` for production. Substitute `iacat-test` / `ppt-test-*` if you're verifying the test deploy.

---

## 0. Pre-flight — confirm you're on the right project

1. Open <https://console.cloud.google.com>.
2. Top bar → **project picker** (next to the Google Cloud logo) → select **`iacat-prod`** (or `iacat-test`).
3. The breadcrumb under the search bar should read `Google Cloud / iacat-prod`. Screenshot this — every later screenshot inherits the project context.

**Tip:** every URL in this guide accepts `?project=iacat-prod` (or `?project=iacat-test`) so you can deep-link directly without manually switching projects.

---

## A. Production VM (Main Server)

### A.1 Quantity: 1

**Console path:** **Compute Engine** → **VM instances**

URL: <https://console.cloud.google.com/compute/instances?project=iacat-prod>

Filter the list with the box above the table: `Labels: role:production`

**PASS:** exactly **one row** matching `role=production`. The instance name is `protectportal-prod` (or `ppt-test-prod` in test).

### A.2 Specs: 16 vCPUs (8 cores), 64 GB RAM

**Console path:** **Compute Engine** → **VM instances** → click `protectportal-prod`

URL: <https://console.cloud.google.com/compute/instancesDetail/zones/asia-southeast1-a/instances/protectportal-prod?project=iacat-prod>

Scroll to the **"Machine configuration"** card.

**PASS:**
```
Machine type:  n2-standard-16
Series:        N2
vCPU:          16 vCPU + 64 GB memory
```

The "vCPU" line literally reads `16 vCPU + 64 GB memory`. Hyperthreading is on by default for N2, so 16 vCPUs = 8 physical cores.

### A.3 Boot Disk: 50 GB SSD (OS)

**Console path:** on the same VM details page → scroll to **"Storage"** card.

**PASS:** The boot disk row shows:
```
Name:        protectportal-prod
Size:        50 GB
Type:        Balanced/SSD persistent disk (the icon shows "SSD")
Mode:        Read/write
Boot:        ✓
```

Click the disk name to drill in for confirmation: type should read **SSD persistent disk** (`pd-ssd`).

### A.4 Data Disk: 2 TB Persistent Disk (Standard SSD)

**Console path:** **Compute Engine** → **Disks**

URL: <https://console.cloud.google.com/compute/disks?project=iacat-prod>

Find the row `protectportal-prod-data`.

**PASS:**
```
Name:          protectportal-prod-data
Size:          2 TB (2,048 GB)
Type:          SSD persistent disk
Zone:          asia-southeast1-a
In use by:     protectportal-prod
Snapshot schedule: protectportal-daily-snapshot (production deploys)
```

> **Spec note:** GCP has no product called "Standard SSD". This Terraform defaults to `pd-ssd` (SSD persistent disk), which satisfies the spec. If your buyer specifically asked for the cheaper `pd-balanced` tier, that's an override in `prod.tfvars`.

### A.5 OS: Ubuntu LTS 64-bit

**Console path:** **Compute Engine** → **VM instances** → click `protectportal-prod` → scroll to **"Boot disk"** card under Storage.

**PASS:**
```
Source image: ubuntu-2204-lts-vYYYYMMDD       (or ubuntu-2204-jammy-vYYYYMMDD)
Architecture: x86/64
```

The image family must include "lts" and the OS version is Ubuntu 22.04 (or whichever LTS your `prod.tfvars` pins via `ubuntu_image`).

### A.6 Availability: 24×7 uptime with auto-restart

**Console path:** VM details page → scroll to **"Management"** card → expand **"Availability policies"** (or scroll to the very bottom under "Availability").

**PASS:**
```
On host maintenance:  Migrate VM instance
Automatic restart:    On (recommended)
Provisioning model:   Standard
Preemptibility:       Off
```

Uptime metric — on the same VM details page, click the **"Observability"** tab (or "Monitoring" depending on UI version). Confirm CPU and Memory time-series have continuous data since the last boot timestamp.

Uptime alert policy:

**Console path:** **Monitoring** → **Alerting**

URL: <https://console.cloud.google.com/monitoring/alerting/policies?project=iacat-prod>

**PASS:** at least one policy named `protectportal HTTPS uptime failed` (present when `enable_https = true`) and the prod CPU/memory/disk alerts. Status column reads `Enabled` for each.

### A.7 Security: Public IP with SSL, firewall rules, monitoring

#### A.7a Public IP (load balancer)

**Console path:** **VPC Network** → **IP addresses**

URL: <https://console.cloud.google.com/networking/addresses/list?project=iacat-prod>

**PASS:** A row named `protectportal-lb-ip`, **Type: External**, **Scope: Global**, **Status: In use by** a forwarding rule.

#### A.7b SSL certificate

**Console path:** **Network Services** → **Load balancing** → click the LB name (`protectportal-...`) → **Frontend** section.

URL: <https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers?project=iacat-prod>

Click the load balancer, then the **Frontend configuration** with port 443.

**PASS:** Certificate column shows `protectportal-managed-cert`, **Status: ACTIVE**.

Drill in via **Network Security** → **Certificate Manager** (or **Compute Engine → SSL certificates**) for the full status:

URL: <https://console.cloud.google.com/security/ccm/list/lbCertificates?project=iacat-prod>

**PASS:** `protectportal-managed-cert` → **Status: Active**, **Domain status: iacat.quanbyit.com — Active**.

End-to-end TLS verification (Console alone can't do this — needs a browser):

Open `https://iacat.quanbyit.com/` in Chrome. Click the padlock → **Connection is secure** → **Certificate is valid**. Issuer should be a Google-managed CA. Screenshot the cert details.

#### A.7c Firewall rules

**Console path:** **VPC Network** → **Firewall**

URL: <https://console.cloud.google.com/networking/firewalls/list?project=iacat-prod>

Filter: `Network: protectportal-vpc`

**PASS:** at least these four rules, all `Enforcement: Enabled`:

| Name | Direction | Targets | Source IP ranges |
| --- | --- | --- | --- |
| `protectportal-allow-iap-ssh` | Ingress | `ssh-iap` tag | `35.235.240.0/20` |
| `protectportal-allow-lb-hc` | Ingress | `http-backend` tag | `130.211.0.0/22`, `35.191.0.0/16` |
| `protectportal-allow-internal` | Ingress | prod/DR tags | prod/DR tags |
| `protectportal-deny-all-ingress` | Ingress | (all) | `0.0.0.0/0` (deny) |

**Confirm there's no 22/tcp from 0.0.0.0/0**: filter `Source IP ranges: 0.0.0.0/0` and inspect each remaining rule's allowed protocols/ports — none should permit `tcp:22`.

#### A.7d Monitoring

**Console path:** **Monitoring** → **Dashboards**

URL: <https://console.cloud.google.com/monitoring/dashboards?project=iacat-prod>

**PASS:** dashboard named `protectportal Overview` is listed. Click it — every panel should be populated (CPU, Memory, Disk, Network for prod; CPU for DR; LB request count).

**Ops Agent running** — back on the VM details page, **Observability** tab. The "Agent" section should read **Ops Agent: installed** with a recent heartbeat timestamp.

### A.8 Usage: Live ProtectPortal hosting

**Console path:** **Network Services** → **Load balancing** → click the LB → **Backend** section.

URL: <https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers?project=iacat-prod>

**PASS:** Backend service `protectportal-backend` shows at least one instance group (`protectportal-prod-ig`) with **Health: 1 of 1 healthy** (green check).

End-to-end from a browser:
- Open `http://iacat.quanbyit.com/` → expect a 301 to HTTPS (when `enable_https=true`).
- Open `https://iacat.quanbyit.com/` → expect a `200 OK` page from your app (or the default nginx welcome page before app deployment).

Screenshot the rendered page + the browser's padlock for the procurement record.

---

## B. DR / Backup Server

### B.1 Quantity: 1

**Console path:** **Compute Engine** → **VM instances**

URL: <https://console.cloud.google.com/compute/instances?project=iacat-prod>

Filter: `Labels: role:disaster-recovery`

**PASS:** exactly one row named `protectportal-dr` in zone `asia-southeast1-b`.

### B.2 Specs: 4 vCPUs (2 cores), 8 GB RAM

**Console path:** click `protectportal-dr` → **"Machine configuration"** card.

URL: <https://console.cloud.google.com/compute/instancesDetail/zones/asia-southeast1-b/instances/protectportal-dr?project=iacat-prod>

**PASS:**
```
Machine type:  n2-custom-4-8192 (Custom)
Series:        N2
vCPU:          4 vCPU + 8 GB memory
```

### B.3 Boot Disk: 50 GB SSD

Same VM details page → **Storage** card → boot disk row.

**PASS:**
- Name: `protectportal-dr`
- Size: `50 GB`
- Type: `SSD persistent disk`
- Boot: ✓

### B.4 Data Disk: 500 GB PD Standard

**Console path:** **Compute Engine** → **Disks**

URL: <https://console.cloud.google.com/compute/disks?project=iacat-prod>

Filter or find `protectportal-dr-data`.

**PASS:**
```
Name:    protectportal-dr-data
Size:    500 GB
Type:    Standard persistent disk    <-- "Standard" = HDD, matches "PD Standard" in the spec
Zone:    asia-southeast1-b
In use by: protectportal-dr
```

### B.5 OS: Ubuntu LTS 64-bit

DR VM details page → **Boot disk** card under Storage.

**PASS:**
```
Source image: ubuntu-2204-lts-vYYYYMMDD
Architecture: x86/64
```

### B.6 Usage: SQL dump + restore validation

This is a runtime behaviour, partially application-layer. From the Console you can confirm:

**1. The 500 GB data disk is mounted on the DR VM** — VM details → **Observability** → **Disk I/O** chart should show non-zero reads on `protectportal-dr-data` once dumps start arriving.

**2. The DR VM has PostgreSQL 16 server + client installed and running** — only verifiable via SSH (use the **SSH** button on the VM details page; it opens a browser-based shell over IAP):

```bash
which psql pg_restore pg_dump
systemctl is-active postgresql
sudo -u postgres psql -tc 'SHOW data_directory;'
```

Expected:
```
/usr/bin/psql /usr/bin/pg_restore /usr/bin/pg_dump
active
 /backups/postgres/16/main
```

Screenshot the browser SSH window.

**3. Recent dumps present** — same browser SSH:
```bash
ls -lhrt /backups/dumps/ | tail -5
```

PASS: at least one `.sql.gz` (or similar) less than 24 hours old.

> **Heads-up:** before the application team wires up the nightly `cron`, this section is N/A. Mark "Pending app deployment" in the sign-off notes rather than failing the infra acceptance.

---

## C. Technical Specifications (Capacity + Add-ons)

### C.1 Hosting coverage for production with dashboards for metrics/logs

**Dashboards:**

URL: <https://console.cloud.google.com/monitoring/dashboards?project=iacat-prod>

**PASS:** `protectportal Overview` dashboard is listed. Open it — six panels (CPU prod, Memory prod, Disk prod, Network prod, CPU DR, LB request count). All should show data.

**Logs:**

URL: <https://console.cloud.google.com/logs/query?project=iacat-prod>

In the query box, paste:
```
resource.type="gce_instance"
resource.labels.instance_id="<numeric_instance_id>"
```

(Get the numeric ID from VM details → "Instance ID" near the top.)

**PASS:** logs from the last hour appear in the results pane, including entries from `google-cloud-ops-agent`.

### C.2 Web Application Firewall (WAF)

**Console path:** **Network Security** → **Cloud Armor policies**

URL: <https://console.cloud.google.com/net-security/securitypolicies/list?project=iacat-prod>

Click `protectportal-waf`.

**PASS:**

| Setting | Value |
| --- | --- |
| Type | `Backend security policy` |
| Adaptive Protection — Layer 7 DDoS Defense | **Enabled** |
| Rules | priorities 1000–1005 (OWASP CRS: SQLi, XSS, LFI, RFI, RCE, scanner detection), 2000 (rate-based ban) |

Click each rule → confirm the expression matches `evaluatePreconfiguredExpr('sqli-v33-stable')` etc.

**Attached to the backend:** scroll down → **Backend services that use this policy** must list `protectportal-backend`.

**Live test from a browser:**

Open `https://iacat.quanbyit.com/?id=1'+OR+'1'='1`

**PASS:** browser shows a `403 Forbidden` page (Cloud Armor blocked the SQLi-shaped request). Screenshot the 403.

### C.3 TLS 1.2 / 1.3

**Console path:** **Network Services** → **Load balancing** → click LB → **Frontend** with port 443 → click the **SSL policy** link.

Or directly: **Compute Engine** → **SSL policies**.

URL: <https://console.cloud.google.com/net-services/loadbalancing/sslPolicies?project=iacat-prod>

Click `protectportal-ssl-policy`.

**PASS:**
```
Profile:           Modern
Min TLS version:   TLS 1.2
Enabled features:  (lists TLS_1_2 and TLS_1_3 ciphersuites)
```

**Live negotiation test:**

Open `https://iacat.quanbyit.com/` in Chrome. Click the padlock → **Connection is secure** → **More information** (or DevTools → Security tab). The protocol line should read **TLS 1.3** for any modern browser. Screenshot it.

For a TLS 1.1 reject test, the Console can't do this directly — see the corresponding section in [SPEC-VERIFICATION.md](SPEC-VERIFICATION.md#c3-tls-12--13) (`curl --tls-max 1.1`).

### C.4 Secure cookies

This is **application-layer**, not visible in the Console without the app running. Once deployed:

1. Open `https://iacat.quanbyit.com/login` (or any page that sets a session cookie).
2. Browser DevTools → **Application** → **Cookies** → the domain.
3. **PASS:** every cookie row shows `HttpOnly ✓`, `Secure ✓`, and a `SameSite` value (`Lax` or `Strict`).

> If the app hasn't been deployed yet, mark this row "Pending app deployment" in the sign-off, not a fail.

### C.5 HSTS

**Console path (config side):** **Network Services** → **Load balancing** → click LB → **Backend** → click `protectportal-backend` → **Edit** → expand **Advanced configuration**.

**PASS:** Custom response headers includes:
```
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
```

**Live header check** (browser):

Open `https://iacat.quanbyit.com/` → DevTools → **Network** tab → reload → click the first request → **Headers** subtab → search Response Headers for `strict-transport-security`.

**PASS:** the header is present with `max-age=63072000`. Screenshot the Headers panel.

### C.6 DDoS protection

**Console path:** **Network Security** → **Cloud Armor policies** → `protectportal-waf` → **Adaptive Protection** section.

URL: <https://console.cloud.google.com/net-security/securitypolicies/list?project=iacat-prod>

**PASS:** Layer 7 DDoS Defense is **Enabled** with a green badge.

**Adaptive Protection findings dashboard:**

URL: <https://console.cloud.google.com/net-security/securitypolicies/adaptiveProtection?project=iacat-prod>

After a few days of traffic, this dashboard surfaces ML-detected anomalies. Initially it shows "No findings" — that's fine for acceptance; the system is armed and listening.

**Rate-based ban rule** — back in the policy → rule with priority 2000 → confirm:
```
Action:              Rate-based ban
Enforce on key:      IP
Threshold count:     600
Threshold interval:  60 seconds
Ban duration:        300 seconds
```

### C.7 Audit logging

**Sink:**

URL: <https://console.cloud.google.com/logs/router?project=iacat-prod>

**PASS:** a row named `protectportal-audit-sink`, **Destination:** `storage.googleapis.com/iacat-prod-protectportal-audit-<random>`, **Status:** Enabled.

Click the sink → **Filter** should include `logName:"cloudaudit.googleapis.com"` and the compute/iam/kms service names.

**Bucket security:**

URL: <https://console.cloud.google.com/storage/browser?project=iacat-prod>

Click the audit bucket → **Configuration** tab.

**PASS:**
- **Access control:** Uniform
- **Public access prevention:** Enforced
- **Object versioning:** Enabled
- **Retention policy:** 1 day (or more for compliance)

**Recent log entries arriving:**

Bucket → **Objects** tab → drill into the most recent date folder.

**PASS:** at least one object dated within the last 24 hours.

### C.8 Vulnerability scanning

**Shielded VM** — on each VM details page (`protectportal-prod` and `protectportal-dr`), scroll to **"Security"** card.

**PASS (both VMs):**
```
Secure Boot:           ✓ Enabled
vTPM:                  ✓ Enabled
Integrity monitoring:  ✓ Enabled
```

**OS patching** — VM details page → **OS info** card (visible when OS Config service is enabled).

URL (overall posture): <https://console.cloud.google.com/compute/osconfig/dashboard?project=iacat-prod>

**PASS:** **Patch deployment** column shows recent activity, **OS Inventory** shows Ubuntu 22.04 packages. (You may need to manually enable OS Config in the project — it's free.)

**Security Command Center** (optional add-on, requires org admin to turn on Premium):

URL: <https://console.cloud.google.com/security/command-center/findings?project=iacat-prod>

**PASS (optional):** the **Findings** page loads and shows zero high/critical findings. If you see "Activate Security Command Center" instead, escalate to the org admin per [docs/SECURITY.md](SECURITY.md#vulnerability-scanning).

### C.9 Backup / DR strategy

**Snapshot schedule:**

URL: <https://console.cloud.google.com/compute/snapshots/snapshotSchedules?project=iacat-prod>

Click `protectportal-daily-snapshot`.

**PASS:**
```
Region:               asia-southeast1
Frequency:            Daily at 17:00 UTC (= 01:00 SGT)
Maximum retention:    30 days
On source disk delete: Keep auto snapshots
Applied to disks:     protectportal-prod-data (asia-southeast1-a)
                      protectportal-dr-data (asia-southeast1-b)
```

**Existing snapshots:**

URL: <https://console.cloud.google.com/compute/snapshots?project=iacat-prod>

Filter by `Source disk` containing `protectportal`.

**PASS:** at least one snapshot per data disk, dated within the last 24 hours (after the schedule has fired at least once).

**Cross-zone DR placement:**

URL: <https://console.cloud.google.com/compute/instances?project=iacat-prod>

The list view's **Zone** column should show:
```
protectportal-prod    asia-southeast1-a
protectportal-dr      asia-southeast1-b
```

**PASS:** the two VMs are in **different zones**. A single-zone outage cannot take down both.

---

## D. Sign-off

Once every section is verified, fill in the form below. Print or paste into the procurement deliverable along with the screenshots.

```
PROTECTPORTAL INFRASTRUCTURE ACCEPTANCE  (Console verification)
================================================================

Environment verified:    [ test  |  production  ]
GCP project:             ____________________________
Console screenshots:     [ attached / not attached ]
Date:                    ____________________________

Verified by:             ____________________________ (signature)
Reviewed by:             ____________________________ (signature)

A. Production VM
  [ ] A.1 Quantity: 1
  [ ] A.2 16 vCPU / 64 GB RAM
  [ ] A.3 50 GB SSD boot
  [ ] A.4 2 TB SSD data
  [ ] A.5 Ubuntu LTS 64-bit
  [ ] A.6 24x7 + auto-restart
  [ ] A.7a Public IP (load balancer)
  [ ] A.7b SSL certificate (ACTIVE)
  [ ] A.7c Firewall rules
  [ ] A.7d Monitoring (dashboard + alerts + Ops Agent)
  [ ] A.8 Live portal hosting (backend HEALTHY)

B. DR Server
  [ ] B.1 Quantity: 1
  [ ] B.2 4 vCPU / 8 GB RAM
  [ ] B.3 50 GB SSD boot
  [ ] B.4 500 GB PD-Standard data
  [ ] B.5 Ubuntu LTS 64-bit
  [ ] B.6 SQL dump + restore validation (or 'Pending app deployment')

C. Technical specifications
  [ ] C.1 Dashboards for metrics/logs
  [ ] C.2 WAF (OWASP CRS rules + live 403 test)
  [ ] C.3 TLS 1.2 / 1.3 (MODERN policy + browser-negotiated TLS 1.3)
  [ ] C.4 Secure cookies (or 'Pending app deployment')
  [ ] C.5 HSTS (header present in browser DevTools)
  [ ] C.6 DDoS protection (Adaptive Protection + rate-ban rule)
  [ ] C.7 Audit logging (sink + WORM bucket + recent objects)
  [ ] C.8 Vulnerability scanning (Shielded VM + OS Config)
  [ ] C.9 Backup/DR (snapshot schedule fired + cross-zone DR)

Screenshots attached for:
  ___________________________________________________________

Notes / exceptions:
  ___________________________________________________________
  ___________________________________________________________
```

---

## Tips for capturing the audit trail

- Use **Snipping Tool** (Windows: `Win + Shift + S`) for each PASS panel. Save with a filename matching the spec line (`A2-machine-config.png`, `C2-cloud-armor-rules.png`).
- Browser zoom 100% for clarity; collapse left-side nav (`Ctrl + B`) to make screenshots wider.
- For multi-rule pages (firewall, Cloud Armor), screenshot the **filtered** list, not the unfiltered one — auditors lose patience scrolling.
- Screenshot timestamps are admissible only if the system clock is shown. Many Console pages don't show a timestamp; if needed, take a parallel screenshot of `Get-Date` in PowerShell as a witness time.
- The Console URL bar always contains `?project=iacat-prod` — visible in every screenshot, doubles as proof of which environment was verified.
