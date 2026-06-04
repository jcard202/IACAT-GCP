# Specification Verification Checklist

A line-by-line acceptance test for the **ProtectPortal Cloud Hosting Infrastructure** procurement. Each spec item is paired with the exact command(s) that prove it's deployed and what a passing result looks like.

Use this document as a **UAT checklist before sign-off**. Walk top to bottom; each section is independent.

---

## 0. Pick your target environment

Every check below uses placeholders for the project, VM names, and zones. Set them once at the top of your PowerShell session so the rest of the doc is copy-pasteable.

**For the production deploy** (full spec sizing):

```powershell
$env:PROJECT  = "iacat-prod"
$env:PROD_VM  = "protectportal-prod"
$env:PROD_ZONE = "asia-southeast1-a"
$env:DR_VM    = "protectportal-dr"
$env:DR_ZONE  = "asia-southeast1-b"
$env:NAME_PREFIX = "protectportal"
$env:DOMAIN   = "iacat.quanbyit.com"
```

**For the test deploy** (smaller sizing — most numeric checks fail intentionally, but structural checks all pass):

```powershell
$env:PROJECT  = "iacat-test"
$env:PROD_VM  = "ppt-test-prod"
$env:PROD_ZONE = "asia-southeast1-a"
$env:DR_VM    = "ppt-test-dr"
$env:DR_ZONE  = "asia-southeast1-b"
$env:NAME_PREFIX = "ppt-test"
$env:DOMAIN   = "iacat-test.quanbyit.com"
```

Quick sanity check before starting:

```powershell
gcloud compute instances list --project=$env:PROJECT `
    --filter="name~'$env:NAME_PREFIX'" `
    --format="table(name,zone.basename(),status,machineType.basename())"
```

Both VMs should be `RUNNING`.

---

## A. Production VM (Main Server)

### A.1 Quantity: 1

```powershell
gcloud compute instances list --project=$env:PROJECT `
    --filter="labels.role=production AND name~'$env:NAME_PREFIX-prod'" `
    --format="value(name)" | Measure-Object -Line
```

**PASS:** `Lines : 1`

### A.2 Specs: 16 vCPUs (8 cores), 64 GB RAM

GCP-side check (the procurement contract):

```powershell
gcloud compute instances describe $env:PROD_VM `
    --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="value(machineType.basename())"
```

**PASS:** `n2-standard-16`  *(16 vCPU = 8 physical cores with hyperthreading enabled, which is GCP's default for N2)*

In-VM cross-check (what the kernel sees):

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command="nproc; lscpu | egrep '^(Core|Socket)'; free -g"
```

**PASS (production):**
```
16
Core(s) per socket:  8
Socket(s):           1
              total  used   free
Mem:          62Gi   ...
```
*(`free -g` reports ~62 GB on a 64 GB box; kernel reserves ~2 GB. Normal.)*

> **Test deploy note:** with `e2-micro` you'll see `2` vCPUs / `0` Gi RAM (`free -g` rounds 1 GB to 0). That's expected for test sizing — the structural check (the command actually runs and parses) is what passes.

### A.3 Boot Disk: 50 GB SSD (OS)

```powershell
gcloud compute instances describe $env:PROD_VM `
    --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="value(disks[0].deviceName,disks[0].boot)"

gcloud compute disks describe $env:PROD_VM `
    --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="table(name,sizeGb,type.basename())"
```

**PASS:**
```
ppt-test-prod      True            <-- first describe, boot=True
NAME             SIZE_GB   TYPE
protectportal-prod  50       pd-ssd     <-- second describe, prod values
```

In-VM cross-check:

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command="lsblk -o NAME,SIZE,TYPE,MOUNTPOINT"
```

**PASS:** Root disk (`sda` or similar) shows ~50G and is mounted at `/`.

### A.4 Data Disk: 2 TB Persistent Disk (Standard SSD)

```powershell
gcloud compute disks describe "$($env:NAME_PREFIX)-prod-data" `
    --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="table(name,sizeGb,type.basename())"
```

**PASS (production):**
```
NAME                   SIZE_GB   TYPE
protectportal-prod-data   2048      pd-ssd
```

**Spec interpretation note:** the spec says "Persistent Disk (Standard SSD)". GCP has no product literally called "Standard SSD". The Terraform defaults to `pd-ssd` (the high-performance SSD tier) for production data; switch to `pd-balanced` if a cost/perf tradeoff is preferred. Both qualify as "SSD" per the spec.

In-VM mount + writeability:

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command="df -hT /data; sudo touch /data/.acceptance-test && sudo rm /data/.acceptance-test && echo writable"
```

**PASS:** `/data` is mounted ext4, size matches the disk, writable.

### A.5 OS: Ubuntu LTS 64-bit

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command="lsb_release -a 2>/dev/null; uname -m"
```

> **PowerShell gotcha:** keep the `--command` argument in double quotes, not single quotes. PowerShell expands `$(...)` substitutions inside single-quoted strings when they're passed to native executables, breaking the bash command. Stick to commands without shell substitution inside the quoted string.

**PASS:**
```
Distributor ID: Ubuntu
Description:    Ubuntu 22.04.x LTS    <-- "LTS" must be in the description
Release:        22.04
Codename:       jammy
Arch: x86_64                          <-- 64-bit
```

### A.6 Availability: 24×7 uptime with auto-restart

Check the GCP scheduling policy:

```powershell
gcloud compute instances describe $env:PROD_VM `
    --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="yaml(scheduling)"
```

**PASS:**
```yaml
scheduling:
  automaticRestart: true       # <-- auto-restart on crash / host event
  onHostMaintenance: MIGRATE   # <-- live-migrate, no downtime during maintenance
  preemptible: false           # <-- not a preemptible instance
  provisioningModel: STANDARD  # <-- not Spot
```

Check uptime since boot (proves it's actually been up):

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command="uptime -p; uptime -s"
```

**PASS:** prints a positive uptime and the start timestamp.

Check the uptime-monitoring alert is wired:

```powershell
gcloud alpha monitoring policies list --project=$env:PROJECT `
    --filter="displayName~'uptime'" `
    --format="value(displayName,enabled)"
```

**PASS:** `ppt-test HTTPS uptime failed  True` (or the prod equivalent) — present only when `enable_https = true`.

### A.7 Security: Public IP with SSL, firewall rules, monitoring

**Public IP (load balancer):**

```powershell
gcloud compute addresses describe "$($env:NAME_PREFIX)-lb-ip" --global --project=$env:PROJECT `
    --format="value(address,status)"
```

**PASS:** an IPv4 address in `IN_USE` status.

**SSL certificate (only when `enable_https = true`):**

```powershell
gcloud compute ssl-certificates describe "$($env:NAME_PREFIX)-managed-cert" --global --project=$env:PROJECT `
    --format="value(managed.status,managed.domainStatus)"
```

**PASS:** `ACTIVE iacat.quanbyit.com=ACTIVE`

End-to-end TLS verification:

```powershell
curl.exe -sI "https://$env:DOMAIN/" | Select-Object -First 6
```

**PASS:**
```
HTTP/2 200
strict-transport-security: max-age=63072000; includeSubDomains; preload
```

**Firewall rules:**

```powershell
gcloud compute firewall-rules list --project=$env:PROJECT `
    --filter="network~'$env:NAME_PREFIX-vpc'" `
    --format="table(name,direction,priority,sourceRanges.list():label=SRC,allowed[].ports.list():label=PORTS,disabled)"
```

**PASS:** at least these four rules, all `disabled=False`:

| Name | Direction | Priority | SRC | Purpose |
| --- | --- | --- | --- | --- |
| `*-allow-iap-ssh` | INGRESS | 1000 | 35.235.240.0/20 | SSH via IAP only |
| `*-allow-lb-hc` | INGRESS | 1000 | 130.211.0.0/22, 35.191.0.0/16 | Load balancer health probes |
| `*-allow-internal` | INGRESS | 1000 | prod↔DR tags | Replication |
| `*-deny-all-ingress` | INGRESS | 65534 | 0.0.0.0/0 | Catch-all deny + audit log |

Confirm there is **no** rule allowing `0.0.0.0/0` on port 22. gcloud's CIDR-in-filter syntax errors out (`Invalid list filter expression`), so dump as JSON and filter in PowerShell:

```powershell
$rules = gcloud compute firewall-rules list --project=$env:PROJECT `
    --filter="network~'$env:NAME_PREFIX-vpc' AND direction=INGRESS" `
    --format="json" | ConvertFrom-Json

$bad = $rules | Where-Object {
    $_.sourceRanges -contains "0.0.0.0/0" -and
    $_.allowed -ne $null -and
    ($_.allowed | Where-Object { $_.ports -contains "22" -or $_.IPProtocol -eq "all" })
}

if ($bad) {
    Write-Host "FAIL: found rule(s) allowing 0.0.0.0/0 on port 22:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  $($_.name)" -ForegroundColor Red }
} else {
    Write-Host "PASS: no rule allows 0.0.0.0/0 on port 22" -ForegroundColor Green
}
```

**PASS:** `PASS: no rule allows 0.0.0.0/0 on port 22`. (Only the `*-deny-all-ingress` rule has `0.0.0.0/0` source — and it's a DENY, not an ALLOW, so it's filtered out by the `$_.allowed -ne $null` check.)

**Monitoring:**

Dashboard exists:
```powershell
gcloud monitoring dashboards list --project=$env:PROJECT --format="value(displayName)" | Select-String "$env:NAME_PREFIX"
```

Alert policies exist:
```powershell
gcloud alpha monitoring policies list --project=$env:PROJECT `
    --format="table(displayName,enabled)" | Select-Object -First 10
```

**PASS:** at least 4 enabled alert policies (CPU, memory, disk, SSH brute-force; +uptime when HTTPS is on).

Ops Agent running inside the VM:

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command='systemctl is-active google-cloud-ops-agent'
```

**PASS:** `active`

### A.8 Usage: Live ProtectPortal hosting

The portal must respond on the public LB IP / domain:

```powershell
$lbIp = gcloud compute addresses describe "$($env:NAME_PREFIX)-lb-ip" --global --project=$env:PROJECT --format="value(address)"
curl.exe -sI "http://$lbIp/"      | Select-Object -First 2
curl.exe -sI "https://$env:DOMAIN/" | Select-Object -First 2
```

**PASS:**
- HTTP returns 301/308 redirect to HTTPS (when `enable_https = true`) or 200 (when off).
- HTTPS returns 200 (when `enable_https = true` and the cert is ACTIVE).

> Windows-bundled `curl.exe` prints `HTTP/1.1` even on HTTP/2 connections — the status code is what matters. To verify HTTP/2 specifically, use a browser's DevTools → Network tab, or install a newer curl (`winget install Hashicorp.curl` or similar).

Backend health:

```powershell
gcloud compute backend-services get-health "$($env:NAME_PREFIX)-backend" --global --project=$env:PROJECT
```

**PASS:** at least one backend in `HEALTHY` state.

---

## B. DR / Backup Server

### B.1 Quantity: 1

```powershell
gcloud compute instances list --project=$env:PROJECT `
    --filter="labels.role=disaster-recovery AND name~'$env:NAME_PREFIX-dr'" `
    --format="value(name)" | Measure-Object -Line
```

**PASS:** `Lines : 1`

### B.2 Specs: 4 vCPUs (2 cores), 8 GB RAM

```powershell
gcloud compute instances describe $env:DR_VM `
    --zone=$env:DR_ZONE --project=$env:PROJECT `
    --format="value(machineType.basename())"
```

**PASS (production):** `n2-custom-4-8192`  *(4 vCPUs = 2 physical cores with HT, 8192 MB = 8 GB)*

In-VM:

```powershell
gcloud compute ssh $env:DR_VM --zone=$env:DR_ZONE --tunnel-through-iap --project=$env:PROJECT --command='nproc; free -g'
```

**PASS:** `4` vCPUs and `7` GB visible RAM (8 GB nominal, ~1 GB kernel-reserved).

### B.3 Boot Disk: 50 GB SSD

```powershell
gcloud compute disks describe $env:DR_VM `
    --zone=$env:DR_ZONE --project=$env:PROJECT `
    --format="table(name,sizeGb,type.basename())"
```

**PASS (production):**
```
NAME              SIZE_GB   TYPE
protectportal-dr   50        pd-ssd
```

### B.4 Data Disk: 500 GB PD Standard

```powershell
gcloud compute disks describe "$($env:NAME_PREFIX)-dr-data" `
    --zone=$env:DR_ZONE --project=$env:PROJECT `
    --format="table(name,sizeGb,type.basename())"
```

**PASS (production):**
```
NAME                  SIZE_GB   TYPE
protectportal-dr-data   500       pd-standard
```

*("PD Standard" maps directly to GCP's `pd-standard` (HDD) tier — used because the DR disk only stores nightly dumps, doesn't need SSD IOPS.)*

Mounted at `/backups`:

```powershell
gcloud compute ssh $env:DR_VM --zone=$env:DR_ZONE --tunnel-through-iap --project=$env:PROJECT --command='df -hT /backups'
```

### B.5 OS: Ubuntu LTS 64-bit

```powershell
gcloud compute ssh $env:DR_VM --zone=$env:DR_ZONE --tunnel-through-iap --project=$env:PROJECT --command='lsb_release -a 2>/dev/null; uname -m'
```

Same expected output as A.5.

### B.6 Usage: Receive daily SQL dump from Production DB; restore to validate

The Terraform provisions the DR VM with the database clients pre-installed and a mount at `/backups`. The actual nightly dump cron is application-layer — verify it exists once you wire it up.

PostgreSQL 16 server + client present and running:

```powershell
gcloud compute ssh $env:DR_VM --zone=$env:DR_ZONE --tunnel-through-iap --project=$env:PROJECT --command="which psql pg_restore pg_dump; systemctl is-active postgresql; sudo -u postgres psql -tc 'SHOW data_directory;'"
```

**PASS:**
```
/usr/bin/psql
/usr/bin/pg_restore
/usr/bin/pg_dump
active
 /backups/postgres/16/main
```

The `data_directory` line confirms the cluster was relocated to the 500 GB data disk at `/backups/postgres/16/main`.

Cron job exists *(only after you've followed the OPERATIONS.md daily-dump setup)*:

```powershell
gcloud compute ssh $env:DR_VM --zone=$env:DR_ZONE --tunnel-through-iap --project=$env:PROJECT --command='ls -la /etc/cron.daily/protectportal-* 2>/dev/null; sudo crontab -l 2>/dev/null | grep -v "^#"'
```

**PASS:** at least one cron entry referencing the restore-validation script.

Most recent dump present:

```powershell
gcloud compute ssh $env:DR_VM --zone=$env:DR_ZONE --tunnel-through-iap --project=$env:PROJECT --command='ls -lhrt /backups/dumps/ 2>/dev/null | tail -5'
```

**PASS:** at least one `.sql.gz` (or whatever extension your dump uses) less than 24 hours old.

---

## C. Technical Specifications (Capacity + Add-ons)

### C.1 Hosting coverage for production with dashboards for metrics/logs

Dashboard:

```powershell
gcloud monitoring dashboards list --project=$env:PROJECT `
    --filter="displayName~'$env:NAME_PREFIX'" `
    --format="value(displayName)"
```

**PASS:** at least `ppt-test Overview` (or `protectportal Overview` in prod).

Logging is collecting from both VMs (~5 min of data minimum):

```powershell
gcloud logging read "resource.type=gce_instance AND resource.labels.instance_id=$(gcloud compute instances describe $env:PROD_VM --zone=$env:PROD_ZONE --project=$env:PROJECT --format='value(id)')" --project=$env:PROJECT --limit=5 --freshness=1h --format="value(timestamp,severity,resource.labels.instance_id)"
```

**PASS:** at least one log line returns. If empty, Ops Agent isn't shipping logs yet.

Open the dashboard in a browser to visually confirm charts populate:

```powershell
Start-Process "https://console.cloud.google.com/monitoring/dashboards?project=$env:PROJECT"
```

### C.2 Web Application Firewall (WAF)

```powershell
gcloud compute security-policies describe "$($env:NAME_PREFIX)-waf" --project=$env:PROJECT `
    --format="yaml(name,type,adaptiveProtectionConfig.layer7DdosDefenseConfig.enable,rules[].description.list())"
```

**PASS:**
- `type: CLOUD_ARMOR`
- `enable: true` under `adaptiveProtectionConfig`
- Rule descriptions include: `Block SQL injection`, `Block XSS`, `Block local file inclusion`, `Block remote file inclusion`, `Block remote code execution`, `Block known scanners`, `Rate limit: 600 req/min per source IP`.

Backend service references the WAF:

```powershell
gcloud compute backend-services describe "$($env:NAME_PREFIX)-backend" --global --project=$env:PROJECT `
    --format="value(securityPolicy.basename())"
```

**PASS:** `<name_prefix>-waf`

End-to-end test — send a query string that triggers the SQLi rule and expect a 403:

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" "https://$env:DOMAIN/?id=1'+OR+'1'='1"
```

**PASS:** `403`

### C.3 TLS 1.2 / 1.3

SSL policy on the proxy:

```powershell
gcloud compute ssl-policies describe "$($env:NAME_PREFIX)-ssl-policy" --project=$env:PROJECT `
    --format="value(name,profile,minTlsVersion,enabledFeatures.list())"
```

**PASS:**
```
<name_prefix>-ssl-policy    MODERN    TLS_1_2    ...
```

End-to-end negotiation test using PowerShell's native `SslStream` (works regardless of the curl version installed on Windows):

```powershell
function Test-TlsHandshake([string]$TargetHost, [System.Security.Authentication.SslProtocols]$Proto) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient($TargetHost, 443)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($TargetHost, $null, $Proto, $false)
        $result = "negotiated: $($ssl.SslProtocol)"
        $ssl.Close(); $tcp.Close()
        return $result
    } catch {
        return "rejected"
    }
}

Write-Host "TLS 1.3 attempt: $(Test-TlsHandshake $env:DOMAIN ([System.Security.Authentication.SslProtocols]::Tls13))"
Write-Host "TLS 1.1 attempt: $(Test-TlsHandshake $env:DOMAIN ([System.Security.Authentication.SslProtocols]::Tls11))"
```

**PASS:**
```
TLS 1.3 attempt: negotiated: Tls13
TLS 1.1 attempt: rejected
```

> Earlier `curl --tls-max 1.1` and `curl -w '%{ssl_version}'` don't work reliably with the curl that ships with Windows 10/11 — the bundled build is missing those features. The `SslStream` test above is built into .NET and works on any Windows with PowerShell 5.1+.

### C.4 Secure cookies

This is an **application-layer** concern (the app must set `Secure; HttpOnly; SameSite=Lax` on every cookie). Once the app is running, verify:

```powershell
curl.exe -sI "https://$env:DOMAIN/login" | Select-String "Set-Cookie"
```

**PASS:** every `Set-Cookie` header includes `Secure`, `HttpOnly`, and `SameSite=Lax` (or `Strict`).

> **If the app hasn't been deployed yet,** this check is N/A — flag it as a follow-up for the app team rather than failing the infra acceptance.

### C.5 HSTS

```powershell
curl.exe -sI "https://$env:DOMAIN/" | Select-String "strict-transport-security"
```

**PASS:** header reads `strict-transport-security: max-age=63072000; includeSubDomains; preload` (2-year max-age satisfies the preload-list requirement).

Header is set at the LB layer (independent of the app), so this works even with a generic backend:

```powershell
gcloud compute backend-services describe "$($env:NAME_PREFIX)-backend" --global --project=$env:PROJECT `
    --format="value(customResponseHeaders.list())"
```

**PASS:** list contains the four security headers (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy).

### C.6 DDoS protection

```powershell
gcloud compute security-policies describe "$($env:NAME_PREFIX)-waf" --project=$env:PROJECT `
    --format="value(adaptiveProtectionConfig.layer7DdosDefenseConfig.enable)"
```

**PASS:** `True`

Per-IP rate-based ban rule:

```powershell
gcloud compute security-policies describe "$($env:NAME_PREFIX)-waf" --project=$env:PROJECT `
    --format="yaml(rules[?priority==2000].rateLimitOptions)"
```

**PASS:** the YAML shows `enforceOnKey: IP`, `rateLimitThreshold.count: 600`, `interval_sec: 60`, `banDurationSec: 300`.

### C.7 Audit logging

Sink exists and writes to GCS:

```powershell
gcloud logging sinks list --project=$env:PROJECT `
    --filter="name~'$env:NAME_PREFIX-audit'" `
    --format="value(name,destination,filter)"
```

**PASS:** sink name ends in `-audit-sink`, destination is `storage.googleapis.com/<bucket>`.

Bucket is properly secured:

```powershell
$auditBucket = gcloud storage buckets list --project=$env:PROJECT --filter="name~'$env:NAME_PREFIX-audit'" --format="value(name)"
gcloud storage buckets describe "gs://$auditBucket" `
    --format="value(name,uniform_bucket_level_access,public_access_prevention,versioning_enabled,retention_policy.retentionPeriod)"
```

**PASS (tab-separated fields):**
```
<bucket-name>   True   enforced   True   86400
```
- `uniform_bucket_level_access: True`
- `public_access_prevention: enforced`
- `versioning_enabled: True`
- `retention_policy.retentionPeriod: 86400` seconds (1 day) — raise for stricter compliance

> The flat-snake-case field names (`uniform_bucket_level_access`, etc.) are what `gcloud storage buckets describe` actually emits. The older camelCase paths from the JSON API (`iamConfiguration.uniformBucketLevelAccess.enabled`) do **not** work with `gcloud storage`'s `--format=value()` and silently return empty.

Recent audit log entries are landing:

```powershell
gcloud storage ls "gs://$auditBucket/" --recursive | Select-Object -Last 5
```

**PASS:** at least one object dated within the last few hours.

### C.8 Vulnerability scans

**Shielded VM** (boot integrity, secure boot, vTPM) — built-in:

```powershell
gcloud compute instances describe $env:PROD_VM --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="value(shieldedInstanceConfig.enableSecureBoot,shieldedInstanceConfig.enableVtpm,shieldedInstanceConfig.enableIntegrityMonitoring)"
gcloud compute instances describe $env:DR_VM --zone=$env:DR_ZONE --project=$env:PROJECT `
    --format="value(shieldedInstanceConfig.enableSecureBoot,shieldedInstanceConfig.enableVtpm,shieldedInstanceConfig.enableIntegrityMonitoring)"
```

**PASS:** `True True True` for both VMs.

**OS-level patching** is automated by `unattended-upgrades`:

```powershell
gcloud compute ssh $env:PROD_VM --zone=$env:PROD_ZONE --tunnel-through-iap --project=$env:PROJECT --command='systemctl is-enabled unattended-upgrades; sudo cat /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -10'
```

**PASS:** `enabled` plus a recent run log entry.

**Network-level vulnerability scanning** (recommended add-on, **not** managed by this Terraform). Confirm Security Command Center is on at the org/project level:

```powershell
gcloud scc settings services list --project=$env:PROJECT 2>$null
```

**PASS (optional):** at least one `service: SECURITY_HEALTH_ANALYTICS` listed and enabled. If not enabled, escalate to org admin — see `docs/SECURITY.md` for the enable command.

### C.9 Backup / DR strategy

> **Test deploys disable snapshots** (`enable_snapshot_schedule = false` in `test.tfvars`). The snapshot-schedule checks below will return "not found" on the test deploy — that's expected. The cross-zone DR placement check applies to both environments.

**Snapshot schedule attached to both data disks** (only when `enable_snapshot_schedule = true`):

```powershell
gcloud compute resource-policies describe "$($env:NAME_PREFIX)-daily-snapshot" --region=asia-southeast1 --project=$env:PROJECT `
    --format="yaml(snapshotSchedulePolicy.schedule.dailySchedule,snapshotSchedulePolicy.retentionPolicy)"
```

**PASS:**
```yaml
dailySchedule:
  daysInCycle: 1
  startTime: '17:00'        # 01:00 SGT (UTC+8)
retentionPolicy:
  maxRetentionDays: 30
  onSourceDiskDelete: KEEP_AUTO_SNAPSHOTS
```

Both data disks attached to the policy:

```powershell
gcloud compute disks describe "$($env:NAME_PREFIX)-prod-data" --zone=$env:PROD_ZONE --project=$env:PROJECT `
    --format="value(resourcePolicies)"
gcloud compute disks describe "$($env:NAME_PREFIX)-dr-data" --zone=$env:DR_ZONE --project=$env:PROJECT `
    --format="value(resourcePolicies)"
```

**PASS:** both list the snapshot policy URI.

At least one snapshot exists once the schedule has fired:

```powershell
gcloud compute snapshots list --project=$env:PROJECT `
    --filter="sourceDisk~'$env:NAME_PREFIX'" `
    --format="table(name,sourceDisk.basename(),storageBytes,creationTimestamp)"
```

**PASS:** at least one snapshot per data disk, dated within the last 24 hours.

**DR VM is in a different zone from prod** (single-zone outage cannot take down both):

```powershell
$prodZone = gcloud compute instances describe $env:PROD_VM --zone=$env:PROD_ZONE --project=$env:PROJECT --format='value(zone.basename())'
$drZone   = gcloud compute instances describe $env:DR_VM   --zone=$env:DR_ZONE   --project=$env:PROJECT --format='value(zone.basename())'
if ($prodZone -ne $drZone) { Write-Host "PASS: prod=$prodZone, dr=$drZone (different zones)" -ForegroundColor Green }
else { Write-Host "FAIL: both in $prodZone" -ForegroundColor Red }
```

---

## D. Sign-off

Once every check above passes, fill in:

```
PROTECTPORTAL INFRASTRUCTURE ACCEPTANCE
=======================================

Environment verified:    [ test  |  production  ]
GCP project:             ____________________________
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
  [ ] A.7 Public IP / SSL / firewall / monitoring
  [ ] A.8 Live portal hosting

B. DR Server
  [ ] B.1 Quantity: 1
  [ ] B.2 4 vCPU / 8 GB RAM
  [ ] B.3 50 GB SSD boot
  [ ] B.4 500 GB PD-Standard data
  [ ] B.5 Ubuntu LTS 64-bit
  [ ] B.6 SQL dump + restore validation cron

C. Technical specifications
  [ ] C.1 Dashboards for metrics/logs
  [ ] C.2 WAF (OWASP CRS rules)
  [ ] C.3 TLS 1.2 / 1.3
  [ ] C.4 Secure cookies (application layer)
  [ ] C.5 HSTS
  [ ] C.6 DDoS protection (Cloud Armor adaptive + rate-ban)
  [ ] C.7 Audit logging (sink to versioned WORM GCS bucket)
  [ ] C.8 Vulnerability scanning (Shielded VM + unattended-upgrades)
  [ ] C.9 Backup / DR strategy (snapshots + cross-zone DR VM)

Notes / exceptions:
__________________________________________________________
__________________________________________________________
__________________________________________________________
```
