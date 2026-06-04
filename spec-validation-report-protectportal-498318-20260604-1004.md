# ProtectPortal Spec Validation Report

**Project:** `protectportal-498318`  
**Name prefix:** `protectportal`  
**Region / zones:** `asia-southeast1` (prod: `asia-southeast1-a`, DR: `asia-southeast1-b`)  
**Domain:** `iacat.quanbyit.com`  
**SSH-based in-VM checks:** SKIPPED (re-run with -IncludeSsh for A.5/A.7d-agent/B.5/B.6/C.8c)  
**Generated:** 2026-06-04 10:10:09 +08:00

> Each check below shows the **command used** (from `docs/SPEC-VERIFICATION.md`) immediately above the result. Copy any command to verify manually.

## Summary

| Status | Count |
| --- | --- |
| PASS | 26 |
| FAIL | 10 |
| INFO | 2 |
| N/A  |   |
| SKIPPED | 2 |
| **Total** | **41** |

## Section A -- Production VM

### A.1 -- Quantity: 1

**Command used:**

```sh
gcloud compute instances list --project=protectportal-498318 --filter="labels.role=production AND name~'protectportal-prod'" --format="value(name)" | Measure-Object -Line
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | Lines : 1 |
| **Actual**   | Lines : 0 |
| **Console navigation** | `Compute Engine -> VM instances` |

### A.2 -- Specs: 16 vCPUs (8 cores), 64 GB RAM

**Command used:**

```sh
gcloud compute instances describe protectportal-prod --zone=asia-southeast1-a --project=protectportal-498318 --format="value(machineType.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | n2-standard-16 |
| **Actual**   | e2-medium |
| **Console navigation** | `Compute Engine -> VM instances -> protectportal-prod` |
| **Notes** | _16 vCPU = 8 physical cores w/ hyperthreading; 64 GB RAM_ |

### A.3 -- Boot disk: 50 GB SSD (OS)

**Command used:**

```sh
gcloud compute disks describe protectportal-prod --zone=asia-southeast1-a --project=protectportal-498318 --format="table(name,sizeGb,type.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | protectportal-prod  50  pd-ssd |
| **Actual**   | protectportal-prod	12	pd-ssd |
| **Console navigation** | `Compute Engine -> Disks -> protectportal-prod` |

### A.4 -- Data disk: 2 TB Persistent Disk (Standard SSD)

**Command used:**

```sh
gcloud compute disks describe protectportal-prod-data --zone=asia-southeast1-a --project=protectportal-498318 --format="table(name,sizeGb,type.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | protectportal-prod-data  2048  pd-ssd  (or pd-balanced as cheaper SSD alt) |
| **Actual**   |  |
| **Console navigation** | `Compute Engine -> Disks -> protectportal-prod-data` |
| **Notes** | _pd-ssd = full SSD; pd-balanced = cost-optimised SSD class. Both satisfy 'Standard SSD' per spec._ |

### A.5 -- OS: Ubuntu LTS 64-bit (boot image source check; SSH check skipped)

**Command used:**

```sh
gcloud compute disks describe protectportal-prod --zone=asia-southeast1-a --project=protectportal-498318 --format="value(sourceImage.basename())"
```

| | |
| --- | --- |
| **Status** | [i] INFO |
| **Expected** | Ubuntu LTS image family in boot disk source image |
| **Actual**   |  |
| **Console navigation** | `Compute Engine -> Disks -> protectportal-prod` |
| **Notes** | _Run with -IncludeSsh for the in-VM lsb_release verification._ |

### A.6 -- Availability: 24x7 with auto-restart

**Command used:**

```sh
gcloud compute instances describe protectportal-prod --zone=asia-southeast1-a --project=protectportal-498318 --format="yaml(scheduling)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | automaticRestart=true, onHostMaintenance=MIGRATE, preemptible=false, provisioningModel=STANDARD |
| **Actual**   | True	MIGRATE	False	STANDARD |
| **Console navigation** | `Compute Engine -> VM instances -> protectportal-prod` |

### A.7a -- Security: Public IP (load balancer)

**Command used:**

```sh
gcloud compute addresses describe protectportal-lb-ip --global --project=protectportal-498318 --format="value(address,status)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | <IPv4>  IN_USE |
| **Actual**   | 8.232.219.109	IN_USE |
| **Console navigation** | `VPC network -> IP addresses` |

### A.7b -- Security: SSL certificate (HTTPS, managed)

**Command used:**

```sh
gcloud compute ssl-certificates describe protectportal-managed-cert --global --project=protectportal-498318 --format="value(managed.status,managed.domainStatus)"
```

| | |
| --- | --- |
| **Status** | [~] SKIPPED |
| **Expected** | ACTIVE  iacat.quanbyit.com=ACTIVE |
| **Actual**   |  |
| **Console navigation** | `Network services -> Load balancing -> [LB name] -> Frontend -> Certificate` |

### A.7c -- Security: Firewall rules (custom VPC, deny-by-default)

**Command used:**

```sh
gcloud compute firewall-rules list --project=protectportal-498318 --filter="network~'protectportal-vpc'" --format="table(name,direction,priority,sourceRanges.list():label=SRC,allowed[].ports.list():label=PORTS,disabled)"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | >=4 rules (allow-iap-ssh, allow-lb-hc, allow-internal, deny-all-ingress) |
| **Actual**   | 0 rules in protectportal-vpc |
| **Console navigation** | `VPC network -> Firewall` |

### A.7c-2 -- Security: NO public-internet SSH (negative test)

**Command used:**

```sh
gcloud compute firewall-rules list --project=protectportal-498318 --filter="network~'protectportal-vpc' AND direction=INGRESS" --format="json" | ConvertFrom-Json | Where-Object { sourceRanges contains 0.0.0.0/0 AND allowed has port 22 }
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | 0 ingress rules allowing 0.0.0.0/0 on port 22 |
| **Actual**   | no rule allows 0.0.0.0/0 -> port 22 |
| **Console navigation** | `VPC network -> Firewall` |

### A.7d-dash -- Security/Monitoring: custom dashboard exists

**Command used:**

```sh
gcloud monitoring dashboards list --project=protectportal-498318 --format="value(displayName)" | Select-String "protectportal"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | >=1 dashboard whose name contains 'protectportal' |
| **Actual**   | 1 matching dashboard(s) |
| **Console navigation** | `Monitoring -> Dashboards` |

### A.7d-alerts -- Security/Monitoring: alert policies enabled

**Command used:**

```sh
gcloud alpha monitoring policies list --project=protectportal-498318 --format="table(displayName,enabled)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | >=4 enabled (CPU, memory, disk, SSH brute-force) |
| **Actual**   | 5 alert policies |
| **Console navigation** | `Monitoring -> Alerting -> Policies` |

### A.8 -- Live ProtectPortal hosting (backend healthy)

**Command used:**

```sh
gcloud compute backend-services get-health protectportal-backend --global --project=protectportal-498318
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | HEALTHY |
| **Actual**   |  |
| **Console navigation** | `Network services -> Load balancing -> Backend services` |

## Section B -- Disaster Recovery VM

### B.1 -- Quantity: 1

**Command used:**

```sh
gcloud compute instances list --project=protectportal-498318 --filter="labels.role=disaster-recovery AND name~'protectportal-dr'" --format="value(name)" | Measure-Object -Line
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | Lines : 1 |
| **Actual**   | Lines : 1 |
| **Console navigation** | `Compute Engine -> VM instances` |

### B.2 -- Specs: 4 vCPUs (2 cores), 8 GB RAM

**Command used:**

```sh
gcloud compute instances describe protectportal-dr --zone=asia-southeast1-b --project=protectportal-498318 --format="value(machineType.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | n2-custom-4-8192 |
| **Actual**   | e2-micro |
| **Console navigation** | `Compute Engine -> VM instances -> protectportal-dr` |

### B.3 -- Boot disk: 50 GB SSD

**Command used:**

```sh
gcloud compute disks describe protectportal-dr --zone=asia-southeast1-b --project=protectportal-498318 --format="table(name,sizeGb,type.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | protectportal-dr  50  pd-ssd |
| **Actual**   | protectportal-dr	13	pd-ssd |
| **Console navigation** | `Compute Engine -> Disks -> protectportal-dr` |

### B.4 -- Data disk: 500 GB PD Standard

**Command used:**

```sh
gcloud compute disks describe protectportal-dr-data --zone=asia-southeast1-b --project=protectportal-498318 --format="table(name,sizeGb,type.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | protectportal-dr-data  500  pd-standard |
| **Actual**   |  |
| **Console navigation** | `Compute Engine -> Disks -> protectportal-dr-data` |

### B.5 -- OS: Ubuntu LTS 64-bit (boot image source check; SSH check skipped)

**Command used:**

```sh
gcloud compute disks describe protectportal-dr --zone=asia-southeast1-b --project=protectportal-498318 --format="value(sourceImage.basename())"
```

| | |
| --- | --- |
| **Status** | [i] INFO |
| **Expected** | Ubuntu LTS image family in boot disk source image |
| **Actual**   |  |
| **Console navigation** | `Compute Engine -> Disks -> protectportal-dr` |
| **Notes** | _Run with -IncludeSsh for the in-VM lsb_release verification._ |

### B.6 -- DR PostgreSQL server (requires SSH)

**Command used:**

```sh
(SSH check skipped; pass -IncludeSsh to run)
```

| | |
| --- | --- |
| **Status** | [~] SKIPPED |
| **Expected** | psql/pg_restore/pg_dump installed; postgresql active; data_directory at /backups/postgres/16/main |
| **Actual**   | (skipped) |
| **Console navigation** | `Compute Engine -> VM instances -> protectportal-dr` |

## Section C -- Technical Specifications

### C.1a -- Hosting coverage: dashboard exists

**Command used:**

```sh
gcloud monitoring dashboards list --project=protectportal-498318 --filter="displayName~'protectportal'" --format="value(displayName)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | >=1 dashboard whose name contains 'protectportal' |
| **Actual**   | protectportal Overview |
| **Console navigation** | `Monitoring -> Dashboards` |

### C.1b -- Hosting coverage: logs flowing from prod VM (last 1h)

**Command used:**

```sh
gcloud logging read "resource.type=gce_instance AND resource.labels.instance_id=<prod-id>" --project=protectportal-498318 --limit=5 --freshness=1h --format="value(timestamp)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | >=1 log entry |
| **Actual**   | 5 log entries in last 1h |
| **Console navigation** | `Logging -> Logs Explorer` |
| **Notes** | _Newly-created VMs may show 0 until Ops Agent has shipped a batch (~5 min)_ |

### C.2 -- Web Application Firewall (WAF)

**Command used:**

```sh
gcloud compute security-policies describe protectportal-waf --project=protectportal-498318 --format="yaml(name,type,adaptiveProtectionConfig.layer7DdosDefenseConfig.enable,rules[].description.list())"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | type=CLOUD_ARMOR + adaptive=True + >=6 OWASP rules |
| **Actual**   | CLOUD_ARMOR	True, 8 rule(s) |
| **Console navigation** | `Network security -> Cloud Armor policies` |

### C.2-2 -- WAF attached to backend service

**Command used:**

```sh
gcloud compute backend-services describe protectportal-backend --global --project=protectportal-498318 --format="value(securityPolicy.basename())"
```

| | |
| --- | --- |
| **Status** | [x] FAIL |
| **Expected** | protectportal-waf |
| **Actual**   |  |
| **Console navigation** | `Network services -> Load balancing -> Backend services` |

### C.2-3 -- WAF blocks SQLi-shaped query (live test)

**Command used:**

```sh
curl.exe -s -o NUL -w "%{http_code}" "https://iacat.quanbyit.com/?id=1'+OR+'1'='1"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | 403 |
| **Actual**   | 403 |
| **Console navigation** | `Network security -> Cloud Armor policies` |

### C.3a -- TLS 1.2 / 1.3: SSL policy

**Command used:**

```sh
gcloud compute ssl-policies describe protectportal-ssl-policy --project=protectportal-498318 --format="value(name,profile,minTlsVersion,enabledFeatures.list())"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | protectportal-ssl-policy  MODERN  TLS_1_2 |
| **Actual**   | protectportal-ssl-policy	MODERN	TLS_1_2 |
| **Console navigation** | `Network services -> Load balancing -> SSL policies` |

### C.3b -- TLS 1.3 negotiation (live test)

**Command used:**

```sh
[Test-TlsHandshake] PowerShell SslStream connect to iacat.quanbyit.com :443 (System.Security.Authentication.SslProtocols::Tls13)
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | negotiated: Tls13 |
| **Actual**   | negotiated: Tls13 |
| **Console navigation** | `Network services -> Load balancing -> SSL policies` |

### C.3c -- TLS 1.1 rejected (live test)

**Command used:**

```sh
[Test-TlsHandshake] PowerShell SslStream connect to iacat.quanbyit.com :443 (System.Security.Authentication.SslProtocols::Tls11)
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | rejected |
| **Actual**   | rejected |
| **Console navigation** | `Network services -> Load balancing -> SSL policies` |

### C.4 -- Secure cookies (application-layer concern)

**Command used:**

```sh
(application-layer; verify after app deployment via DevTools/Cookies)
```

| | |
| --- | --- |
| **Status** | [-] N/A |
| **Expected** | Every Set-Cookie includes Secure; HttpOnly; SameSite=Lax\|Strict |
| **Actual**   | N/A -- infra cannot enforce; app team responsibility |

### C.5 -- HSTS header (live response from LB)

**Command used:**

```sh
curl.exe -sI "https://iacat.quanbyit.com/" | Select-String "strict-transport-security"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | Strict-Transport-Security: max-age=...; includeSubDomains; preload |
| **Actual**   | max-age=63072000; includeSubDomains; preload |
| **Console navigation** | `Network services -> Load balancing -> Backend services` |

### C.5-2 -- Security response headers configured at LB

**Command used:**

```sh
gcloud compute backend-services describe protectportal-backend --global --project=protectportal-498318 --format="value(customResponseHeaders.list())"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | HSTS + X-Content-Type-Options + X-Frame-Options + Referrer-Policy |
| **Actual**   | Referrer-Policy: strict-origin-when-cross-origin,X-Frame-Options: DENY,X-Content-Type-Options: nosniff,Strict-Transport-Security: max-age=63072000; includeSubDomains; preload |
| **Console navigation** | `Network services -> Load balancing -> Backend services` |

### C.6a -- DDoS protection: Cloud Armor adaptive L7

**Command used:**

```sh
gcloud compute security-policies describe protectportal-waf --project=protectportal-498318 --format="value(adaptiveProtectionConfig.layer7DdosDefenseConfig.enable)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | True |
| **Actual**   | True |
| **Console navigation** | `Network security -> Cloud Armor policies` |

### C.6b -- DDoS protection: per-IP rate-based ban rule

**Command used:**

```sh
gcloud compute security-policies describe protectportal-waf --project=protectportal-498318 --format=json  # then select rules[priority==2000].rateLimitOptions
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | enforceOnKey=IP, count=600/60s, banDurationSec=300 |
| **Actual**   | enforceOnKey=IP, count=600, intervalSec=60, banDurationSec=300, exceedAction=deny(429) |
| **Console navigation** | `Network security -> Cloud Armor policies` |

### C.7a -- Audit log sink exists

**Command used:**

```sh
gcloud logging sinks list --project=protectportal-498318 --filter="name~'protectportal-audit'" --format="value(name,destination,filter)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | protectportal-audit-sink -> storage.googleapis.com/<bucket> |
| **Actual**   | protectportal-audit-sink	storage.googleapis.com/protectportal-498318-protectportal-audit-691f4d3e |
| **Console navigation** | `Logging -> Log Router` |

### C.7b -- Audit bucket hardened

**Command used:**

```sh
gcloud storage buckets describe gs://protectportal-498318-protectportal-audit-691f4d3e --format="value(name,uniform_bucket_level_access,public_access_prevention,versioning_enabled,retention_policy.retentionPeriod)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | UBLA=True, PAP=enforced, versioning=True, retentionPeriod>=86400 |
| **Actual**   | protectportal-498318-protectportal-audit-691f4d3e	True	enforced	True	86400 |
| **Console navigation** | `Cloud Storage -> Buckets -> protectportal-498318-protectportal-audit-691f4d3e -> Configuration` |

### C.8a -- Vulnerability scans: Shielded VM (prod)

**Command used:**

```sh
gcloud compute instances describe protectportal-prod --zone=asia-southeast1-a --project=protectportal-498318 --format="value(shieldedInstanceConfig.enableSecureBoot,shieldedInstanceConfig.enableVtpm,shieldedInstanceConfig.enableIntegrityMonitoring)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | True  True  True |
| **Actual**   | True	True	True |
| **Console navigation** | `Compute Engine -> VM instances -> protectportal-prod` |

### C.8b -- Vulnerability scans: Shielded VM (DR)

**Command used:**

```sh
gcloud compute instances describe protectportal-dr --zone=asia-southeast1-b --project=protectportal-498318 --format="value(shieldedInstanceConfig.enableSecureBoot,shieldedInstanceConfig.enableVtpm,shieldedInstanceConfig.enableIntegrityMonitoring)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | True  True  True |
| **Actual**   | True	True	True |
| **Console navigation** | `Compute Engine -> VM instances -> protectportal-dr` |

### C.9a -- Backup/DR: Backup & DR Service vault exists

**Command used:**

```sh
gcloud alpha backup-dr backup-vaults describe protectportal-backup-vault --location=asia-southeast1 --project=protectportal-498318 --format="value(name,state,backupMinimumEnforcedRetentionDuration)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | state=ACTIVE, backupMinimumEnforcedRetentionDuration set |
| **Actual**   | ACTIVE	P30D |
| **Console navigation** | `Backup and DR -> Backup vaults -> protectportal-backup-vault` |

### C.9b -- Backup/DR: daily backup plan for VMs

**Command used:**

```sh
gcloud alpha backup-dr backup-plans describe protectportal-daily-backup --location=asia-southeast1 --project=protectportal-498318 --format="value(name,resourceType,backupRules[0].standardSchedule.recurrenceType,backupRules[0].backupRetentionDays)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | resourceType=compute.googleapis.com/Instance, DAILY recurrence, retentionDays set |
| **Actual**   | compute.googleapis.com/Instance	DAILY	30 |
| **Console navigation** | `Backup and DR -> Backup plans -> protectportal-daily-backup` |

### C.9c -- Backup/DR: both VMs associated with the backup plan

**Command used:**

```sh
gcloud alpha backup-dr backup-plan-associations list --location=asia-southeast1 --project=protectportal-498318 --format="value(name,resource,backupPlan.basename())"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | associations exist: protectportal-prod-association and protectportal-dr-association |
| **Actual**   | prod-associated=True, dr-associated=True |
| **Console navigation** | `Backup and DR -> Backup plans -> protectportal-daily-backup -> Resources` |

### C.9d -- Backup/DR: legacy disk snapshot policy (optional)

**Command used:**

```sh
gcloud compute resource-policies describe protectportal-daily-snapshot --region=asia-southeast1 --project=protectportal-498318 --format="value(snapshotSchedulePolicy.schedule.dailySchedule.daysInCycle,snapshotSchedulePolicy.retentionPolicy.maxRetentionDays)"
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | Daily, maxRetentionDays>=7 (or 'not present' if relying on Backup & DR Service alone) |
| **Actual**   | 1	30 |
| **Console navigation** | `Compute Engine -> Snapshots -> Snapshot schedules` |

### C.9e -- Backup/DR: prod + DR in different zones

**Command used:**

```sh
gcloud compute instances describe protectportal-prod/protectportal-dr --format='value(zone.basename())'  (compare results)
```

| | |
| --- | --- |
| **Status** | [v] PASS |
| **Expected** | prod zone != DR zone |
| **Actual**   | prod=asia-southeast1-a, dr=asia-southeast1-b |
| **Console navigation** | `Compute Engine -> VM instances` |

---

Generated by `scripts/validate-spec.ps1`. For the manual checklist this script automates, see `docs/SPEC-VERIFICATION.md`.

