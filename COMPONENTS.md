# Component Reference

Companion to [`ARCHITECTURE.md`](./ARCHITECTURE.md). That file answers **what** the stack contains and how the pieces connect. This file answers **why** each piece is configured the way it is — what it does, what we wanted from it, and what the configuration trade-off was.

Each section follows the same shape:

- **Description** — what the resource is, in one or two sentences.
- **Purpose** — what role it plays in the system.
- **Why configured this way** — the rationale behind the specific knobs we chose.

---

## 1. Network layer

### 1.1 Custom VPC (`google_compute_network.vpc`)

- **Description.** A VPC with `auto_create_subnetworks = false` — no built-in subnets, no implicit firewall rules.
- **Purpose.** Provide the network boundary that everything else lives inside, and isolate ProtectPortal from any other project workload.
- **Why configured this way.** The default GCP network is auto-mode: it pre-creates a subnet in every region and opens permissive firewall rules (ICMP/RDP/SSH from anywhere). Auto-mode is fine for sandboxes; for a production portal it is unacceptable — every subnet is a piece of attack surface that has to be re-locked-down. Custom mode means we declare exactly the subnets we want, in exactly the CIDRs we choose, with deny-by-default firewall posture from second zero.

### 1.2 Subnets — prod and DR (`google_compute_subnetwork.prod`, `google_compute_subnetwork.dr`)

- **Description.** Two `/24` subnets in `asia-southeast1`, one per zone (`-a` for prod, `-b` for DR). VPC Flow Logs enabled at 50% sampling.
- **Purpose.** Place the two VMs in physically separate failure domains while keeping them on the same private network for cross-zone replication.
- **Why configured this way.**
  - **Different zones, same region.** A single-zone outage is the most common GCP failure mode. Splitting prod/DR across zones eliminates that as a single point of failure while keeping intra-region latency in the low-millisecond range, which matters for the DR VM's nightly pg_dump.
  - **`/24` (256 IPs).** Comfortable headroom for current workload (2 VMs) plus future LB proxies and internal services. Smaller (`/28`) would force a subnet rebuild on the next growth; larger wastes a private range we may want for a second project.
  - **Flow Logs at 50%.** 100% sampling is full forensic fidelity but expensive on a chatty database VM. 50% is the standard balance — enough to reconstruct an incident, half the log spend.

### 1.3 Cloud Router + Cloud NAT (`google_compute_router.router`, `google_compute_router_nat.nat`)

- **Description.** A regional Cloud Router announcing the VPC's subnets, plus a Cloud NAT gateway that does outbound NAT for any VM without a public IP.
- **Purpose.** Let the DR VM (and any future private workloads) reach the internet for `apt update`, `gcloud`, certbot, etc., without giving it an inbound public IP.
- **Why configured this way.** The DR VM intentionally has no public IP — that removes a whole class of inbound attack surface. But it still needs egress for OS updates and backup operations. Cloud NAT is the managed solution: no NAT VM to patch, automatic high availability, regional scaling.

### 1.4 Reserved global IP (`google_compute_global_address.lb_ip`)

- **Description.** A reserved global external IP, attached to the HTTPS load balancer.
- **Purpose.** Provide a stable anycast IP that the GoDaddy `A` record points at.
- **Why configured this way.** Without the reservation, the LB's IP would be allocated only when the forwarding rule is created and released when it's destroyed — meaning every `terraform destroy && terraform apply` cycle would shuffle the IP and break DNS. Reserving it makes the IP a first-class resource that survives LB rebuilds.

---

## 2. Firewall (`firewall.tf`)

The firewall posture is **deny-by-default**: there is no allow rule with `0.0.0.0/0` as a source on any port except 80/443 to the LB (which goes through Cloud Armor first). Every other ingress is explicit.

### 2.1 IAP SSH (`allow_iap_ssh`)

- **Description.** Allow TCP/22 from `35.235.240.0/20` (Google's IAP egress range) to any VM tagged `ssh-iap`.
- **Purpose.** Operator access to the VMs without exposing port 22 to the internet.
- **Why configured this way.** IAP terminates the SSH session at Google's identity-aware proxy, which authenticates the operator against the project's IAM (including OS Login) before tunnelling to the VM. The 35.235.240.0/20 range is documented and stable. Allowing only this source means a port-22 scanner from the internet sees no open port at all — the firewall drops the SYN before sshd even sees it.

### 2.2 LB health checks (`allow_lb_health_checks`)

- **Description.** Allow TCP/80 and TCP/443 from Google's LB health check ranges (`130.211.0.0/22`, `35.191.0.0/16`) to anything tagged `http-backend`.
- **Purpose.** Let the LB confirm the backend is alive before sending real traffic.
- **Why configured this way.** GCP LB health checks come from documented, fixed source ranges. Narrowing the rule to those CIDRs (instead of `0.0.0.0/0`) means a script-kiddie hitting the VM's public IP directly cannot trigger health check responses or bypass Cloud Armor.

### 2.3 Internal prod ↔ DR (`allow_internal_prod_dr`)

- **Description.** Allow TCP/22, TCP/5432, and ICMP between VMs tagged `protectportal-prod` and `protectportal-dr`.
- **Purpose.** Let the DR VM pull PostgreSQL dumps from prod (5432), run remote health checks (22), and verify reachability (ICMP).
- **Why configured this way.** The rule is target-tag-to-source-tag, not CIDR-to-CIDR. Tag-based rules survive subnet renumbering and are explicit about *which workloads* talk to each other — not just *which addresses* happen to be in scope today.

### 2.4 Deny-all logging rule (`deny_all_ingress`)

- **Description.** A low-priority deny rule covering `0.0.0.0/0` → all ports → all protocols, with logging enabled.
- **Purpose.** Make implicit drops visible. GCP already denies-by-default, but those drops are silent.
- **Why configured this way.** Without this rule, a port scan against your IP shows up nowhere — the packet is dropped silently and you never know it happened. With this rule, every dropped packet creates a flow log entry, which lets the monitoring layer alert on unusual scan patterns. The cost is small (denied traffic is by definition low volume) and the visibility is large.

---

## 3. IAM (`iam.tf`)

### 3.1 Per-VM service accounts (`google_service_account.prod_vm`, `dr_vm`)

- **Description.** Two dedicated service accounts, one per VM, each granted only the roles required for the Ops Agent and Artifact Registry pulls.
- **Purpose.** Give each VM exactly the permissions it needs, no more.
- **Why configured this way.**
  - **Per-VM accounts (not shared).** If the prod VM's credentials are ever compromised, the blast radius is limited to that VM's permissions. Shared service accounts mean a single credential leak compromises both tiers.
  - **No `roles/owner`, `roles/editor`, or `roles/compute.admin`.** A VM that's exposed to internet traffic should never be able to mint other VMs, modify firewall rules, or read other workloads' state. The roles we grant are write-only telemetry (`logging.logWriter`, `monitoring.metricWriter`) and read-only metadata (`stackdriver.resourceMetadata.writer`, `monitoring.viewer`, `artifactregistry.reader`).
  - **`cloud-platform` scope on the instance.** Without this scope, even an explicitly-granted IAM role is ignored by GCP APIs called from the VM. With it, IAM is the only thing that bounds what the VM can do — and IAM is minimal. This is the recommended posture from Google.

---

## 4. Compute (`compute.tf`)

### 4.1 Production VM (`google_compute_instance.prod` or `_from_machine_image.prod`)

- **Description.** `n2-standard-16` (16 vCPU / 64 GB RAM) in `asia-southeast1-a`, 50 GB SSD boot, 2 TB SSD data disk, Ubuntu 22.04 LTS, with a temporary public IP for bootstrap.
- **Purpose.** Host the customer-facing portal (nginx, the application, PostgreSQL 16 primary).
- **Why configured this way.**
  - **`n2-standard-16` not `e2-standard-16`.** N2 is the higher-baseline performance tier with reserved CPU. E2 is cheaper but bursty and shared. For a database VM doing predictable transactional load, N2's deterministic latency is worth the ~20% premium.
  - **`pd-ssd` for the data disk** (rather than `pd-balanced` or `pd-standard`). The data disk is the PostgreSQL cluster's data directory. PG's checkpoint and WAL fsyncs are latency-sensitive — `pd-ssd` gives 3 IOPS/GB baseline, `pd-balanced` 6 IOPS/GB but lower throughput, and `pd-standard` is HDD-class and unsuitable for an OLTP database.
  - **`pd-ssd` for the 50 GB boot disk.** Cheap insurance — boot reads dominate the OS responsiveness experience during patching/restarts, and 50 GB at SSD pricing is rounding error compared to the data disk.
  - **Public IP via `access_config`.** Required for first-deploy bootstrap (when the LB hasn't seen a healthy backend yet, you can't reach the VM through the LB). Documented to be removed after LB cutover so all traffic flows through Cloud Armor.
  - **`deletion_protection = true`.** A misclick in the console or a `terraform destroy` without `prevent_destroy` should not be able to delete the prod VM. Combined with `prevent_destroy` on the data disk, recreating the VM is intentional, not accidental.
  - **`automatic_restart = true`, `on_host_maintenance = MIGRATE`.** GCP rolls out host-level updates regularly. `MIGRATE` lets the VM live-migrate to a new host without downtime; `automatic_restart` catches the rare cases where migration fails and a cold restart is needed. Combined, this is the 24×7-auto-restart spec requirement.

### 4.2 DR VM (`google_compute_instance.dr` or `_from_machine_image.dr`)

- **Description.** `n2-custom-4-8192` (4 vCPU / 8 GB RAM) in `asia-southeast1-b`, 50 GB SSD boot, 500 GB pd-standard data disk, no public IP.
- **Purpose.** Receive nightly PostgreSQL dumps from prod, validate them by restore, and stand ready for manual cutover if prod is lost.
- **Why configured this way.**
  - **`n2-custom-4-8192` instead of a standard shape.** The DR VM is idle most of the day, then bursts during the nightly dump+restore cycle. Custom sizing lets us pick the minimum vCPU count that keeps the restore inside the maintenance window, without paying for unused RAM that an off-the-shelf shape would force on us.
  - **`pd-standard` (HDD) for the data disk.** Backups are write-once, read-rarely. HDD is the cheapest option and the sequential write throughput is fine for a `pg_dump | gzip` stream — random IOPS don't matter when you're never doing random reads.
  - **`pd-ssd` for the boot disk.** Same argument as prod — the boot disk is small and SSD pricing is rounding error.
  - **No public IP.** The DR VM does not serve traffic, ever. Removing the public IP removes a whole class of attack surface; egress for `apt`/`gcloud` goes via Cloud NAT.
  - **Different zone from prod.** Single-zone outages are the most common failure. If the DR VM were in the same zone as prod, a zone failure would take out both at once.

### 4.3 Separate data disks (`google_compute_disk.prod_data`, `dr_data`)

- **Description.** The 2 TB (prod) and 500 GB (DR) data disks are declared as standalone `google_compute_disk` resources with `prevent_destroy = true`, then attached to their VM via `google_compute_attached_disk`.
- **Purpose.** Let the VM be rebuilt, retyped, or re-imaged without losing data.
- **Why configured this way.** If the data disk were a sub-block inside the `google_compute_instance` (`boot_disk` style), destroying the VM would destroy the disk. By separating them and marking the disk `prevent_destroy`, you can `terraform taint` the VM, change the machine type, or rebuild from a fresh image — the disk persists and reattaches. This is the canonical pattern for stateful workloads on GCP.

### 4.4 Shielded VM config (`shielded_instance_config`)

- **Description.** Secure boot, vTPM, and integrity monitoring all enabled.
- **Purpose.** Detect and refuse to boot a VM whose firmware, bootloader, or kernel has been tampered with.
- **Why configured this way.** This is the C.8 spec requirement (vulnerability scans / boot integrity). Secure boot verifies signed UEFI bootloader and kernel modules; vTPM provides hardware-backed attestation; integrity monitoring continuously compares the boot-time PCR values against a baseline and alerts on drift. Together they make rootkit-class persistence dramatically harder to hide.

### 4.5 OS Login + SSH lockdown

- **Description.** `enable-oslogin = TRUE`, `block-project-ssh-keys = TRUE`, `serial-port-enable = FALSE`.
- **Purpose.** Make IAM (not `/etc/passwd`) the source of truth for VM access.
- **Why configured this way.**
  - **OS Login** maps the operator's Google identity to a POSIX user, with public keys pulled from IAM. Revoke IAM, lose SSH access — no `authorized_keys` drift.
  - **Block project SSH keys** prevents an old project-wide key from quietly granting access. Some projects accumulate years of legacy keys; this rule says "don't honour them, this VM."
  - **Disable serial port.** Serial port access can bypass SSH/OS Login entirely. We re-enable temporarily only for emergency recovery if SSH itself breaks.

---

## 5. Backup & DR (`backup-dr.tf` + `compute.tf` snapshot policy)

We deliberately run **two backup tiers**. Each has gaps the other covers.

### 5.1 Backup Vault (`google_backup_dr_backup_vault.main`)

- **Description.** A regional Backup & DR Service vault with a 30-day minimum-enforced retention.
- **Purpose.** Hold immutable copies of the VMs that even a compromised Owner cannot delete early.
- **Why configured this way.** The vault's `backupMinimumEnforcedRetentionDuration` is the WORM lock — once a backup lands, it cannot be deleted until that duration expires, *full stop*. This is the property that defends against ransomware-with-credentials scenarios: an attacker who steals an Owner role token can delete VMs and disks, but cannot delete the backup vault contents. 30 days is the spec target.

### 5.2 Backup Plan — daily (`google_backup_dr_backup_plan.daily`)

- **Description.** A daily DAILY-recurrence plan, runs in the 17–19 UTC window (01–03 SGT), retains 30 days.
- **Purpose.** Drive the actual backup runs. The vault is the storage; the plan is the schedule.
- **Why configured this way.**
  - **Window 17–19 UTC (01–03 SGT).** Off-peak for a Singapore customer base. The window says *when the engine may start*, not how long it runs — actual backup duration is a few minutes.
  - **Daily recurrence + 30-day retention.** Matches the vault retention. 30 daily restore points covers the typical "we discovered the bad commit three weeks ago" scenario.
  - **`resource_type = compute.googleapis.com/Instance`.** Plans are type-scoped. A single VM plan can't accidentally apply to disks, buckets, or databases.

### 5.3 Plan associations — prod + DR (`google_backup_dr_backup_plan_association.prod`, `.dr`)

- **Description.** Two associations binding the daily plan to each VM by instance self-link.
- **Purpose.** Tell the plan *which resources* to back up. Without an association, the plan does nothing.
- **Why configured this way.** Associations are explicit and per-resource (not by tag or label). That is intentional: a typo in a label should not silently remove a VM from backup coverage. The plan-association is a hard Terraform reference, so any drift will surface in the next `terraform plan`.

### 5.4 Disk snapshot policy (`google_compute_resource_policy.daily_snapshot`)

- **Description.** A daily snapshot resource-policy attached to both data disks, retaining for 30 days.
- **Purpose.** A second, independent backup tier at the GCE-PD level — cheaper and lower-latency to restore than vault backups.
- **Why configured this way.** This is belt-and-suspenders. Vault backups are application-consistent and immutable but slower to restore and incur vault storage costs. Disk snapshots are disk-level (not application-consistent — a write in flight at snapshot time can land partially), but restore in minutes and cost a fraction. We keep both because the failure modes are different: a vault outage doesn't affect snapshots, and vice versa.

---

## 6. Load balancer & edge security (`lb.tf`)

### 6.1 Global HTTPS Load Balancer (`google_compute_global_forwarding_rule.https`, etc.)

- **Description.** Global External Application Load Balancer (`EXTERNAL_MANAGED`), single anycast IP, HTTPS on 443.
- **Purpose.** Be the single termination point for customer traffic, applying TLS, WAF, and rate limiting before anything reaches the VM.
- **Why configured this way.**
  - **Global anycast IP.** Routes the user to the nearest Google edge — ~150 ms response globally. Without this, every customer hits Singapore directly with the full RTT penalty.
  - **`EXTERNAL_MANAGED` scheme.** The newer LB stack with native Cloud Armor and adaptive protection support. The legacy `EXTERNAL` (non-managed) is in maintenance mode and won't gain new features.
  - **Backend tier with health-checked instance group.** Even a single-VM backend is wrapped in an instance group so the LB knows when the VM is unhealthy and can serve 502 instead of timing out.

### 6.2 Managed SSL certificate (`google_compute_managed_ssl_certificate.portal`)

- **Description.** Google-managed certificate for `var.domain_name`. Auto-renews.
- **Purpose.** Provide a trusted TLS certificate without us managing certbot, renewals, or private keys.
- **Why configured this way.** Self-managed certs (Let's Encrypt + certbot) work, but require the VM to be reachable for ACME challenges and the renewal job to never fail silently. Google-managed certs validate against the LB itself, renew 30 days before expiry, and never expose us to a private key. The one cost: 15–60 minutes between LB attach and `ACTIVE` status while Google validates the DNS.

### 6.3 SSL policy — MODERN (`google_compute_ssl_policy.modern`)

- **Description.** SSL policy profile `MODERN`, `min_tls_version = TLS_1_2`.
- **Purpose.** Enforce strong TLS without breaking the long tail of older clients.
- **Why configured this way.** GCP offers three profiles:
  - `COMPATIBLE` — allows TLS 1.0/1.1 and weak ciphers. Rejected: weak ciphers fail compliance.
  - `MODERN` — TLS 1.2+, modern ciphers, broad client compatibility. **Selected.**
  - `RESTRICTED` — TLS 1.2+, tight cipher list. Rejects some older Android, embedded clients.
  
  `MODERN` is the sweet spot for a public portal. `RESTRICTED` is the right answer if PCI-DSS requires strong-ciphers-only evidence — toggleable via `var.ssl_profile`.

### 6.4 Cloud Armor — WAF + adaptive + rate-ban (`google_compute_security_policy.waf`)

- **Description.** Cloud Armor policy with OWASP Core Rule Set preconfigured rules, Layer-7 adaptive DDoS protection enabled, and a rate-based ban rule (600 req/60s/IP, 5-minute ban on exceed).
- **Purpose.** Drop malicious traffic before it reaches the application.
- **Why configured this way.**
  - **OWASP CRS rules** (SQLi, XSS, LFI, RFI, RCE, scanner detection). These are Google-managed preconfigured expressions — kept up to date by Google's security team, no rule-tuning burden on us.
  - **Adaptive Protection** (`adaptiveProtectionConfig.layer7DdosDefenseConfig.enable = true`). Machine-learning model on the LB layer that detects volumetric and L7 application attacks. Free with Cloud Armor Standard.
  - **Rate-based ban at 600 req/min/IP.** Picked to be well above what a legitimate browser session generates (a heavy SPA load ~50–100 requests). 600 catches abusive scripts and credential-stuffing without false-positiving real users.
  - **`banDurationSec = 300`.** Five minutes is short enough that a falsely-banned user can come back, long enough that an attacker has to rotate IPs constantly.
  - **`enforceOnKey = IP`.** Per-source-IP rate limiting. Could also be per-cookie or per-header; IP is the right granularity for an unauthenticated edge.

### 6.5 Security response headers (`custom_response_headers`)

- **Description.** Strict-Transport-Security, X-Content-Type-Options, X-Frame-Options, Referrer-Policy injected at the LB.
- **Purpose.** Defence-in-depth against browser-side attack classes (TLS stripping, MIME sniffing, clickjacking, referrer leakage).
- **Why configured this way.**
  - **HSTS with `max-age=63072000` (2 years), `includeSubDomains`, `preload`.** Forces every subsequent connection over HTTPS even if the user types `http://`. The `preload` directive opts into Chrome's hardcoded HSTS list.
  - **`X-Content-Type-Options: nosniff`** prevents the browser from guessing MIME types — a classic vector for serving content as the wrong type and bypassing CSP.
  - **`X-Frame-Options: DENY`** blocks framing entirely — clickjacking defence.
  - **`Referrer-Policy: strict-origin-when-cross-origin`** stops the portal from leaking full URLs (with query params) to third parties.
  
  Injecting at the LB (not the app) means a misconfigured app cannot accidentally drop these headers.

### 6.6 HTTP → HTTPS redirect (`google_compute_url_map.http_redirect`)

- **Description.** A separate URL map on port 80 that 301-redirects all traffic to `https://<host><path>`.
- **Purpose.** Eliminate accidental cleartext connections.
- **Why configured this way.** Implemented as a redirect URL map rather than an app-level redirect: the redirect happens at the LB itself, so we don't need a port-80 listener on the backend at all. Less attack surface, no SSL stripping window.

---

## 7. Monitoring (`monitoring.tf`)

### 7.1 Email notification channel (`google_monitoring_notification_channel.email`)

- **Description.** A single email channel pointing at `var.alert_email`.
- **Purpose.** Deliver alerts to a human who can act on them.
- **Why configured this way.** Started simple — one channel, email. Easy to add PagerDuty/Slack/SMS as additional channels later by appending to the alert policies' `notification_channels` list. Single channel keeps the Day-1 setup cost low without precluding richer routing later.

### 7.2 Uptime check (`google_monitoring_uptime_check_config.portal_https`)

- **Description.** HTTPS GET `/` every 60 seconds, SSL validation enabled, checked from multiple global regions.
- **Purpose.** First line of detection if the portal is down externally.
- **Why configured this way.**
  - **60-second period.** The minimum supported and the right answer for a customer-facing portal — anything longer leaves a multi-minute "I think it's still up" window after an outage.
  - **Multi-region.** GCP's uptime checks run from several regions; an outage in one region doesn't false-positive. A single-region outcome that disagrees with the others is treated as a probe-side issue, not a backend issue.
  - **SSL validation on.** Catches expired/misconfigured certificates as outages.

### 7.3 Alert policies (`google_monitoring_alert_policy.*`)

- **Description.** Five policies — CPU > 85% for 5m, memory > 90% for 5m, disk > 85% for 10m, uptime failure, SSH brute-force.
- **Purpose.** Page a human only when something needs human attention.
- **Why configured this way.** The thresholds and durations are picked to minimize false-positives:
  - CPU 85%/5m is high enough to ignore normal spikes (cron, GC, backups) but catches sustained load.
  - Disk 85%/10m is the disk-filling-up early warning — not panic, but enough lead time to clean up before things break.
  - SSH brute-force fires on > 20 failed logins in 5 minutes — well above any single fat-fingered operator, low enough to catch automated dictionary attacks.

### 7.4 Log-based metric — failed SSH (`google_logging_metric.failed_ssh`)

- **Description.** A counter metric that increments on log entries matching `Failed password` or `Invalid user` in syslog/auth.
- **Purpose.** Feed the SSH brute-force alert policy.
- **Why configured this way.** OS Login records authentication failures via standard syslog. A log-based metric turns text events into a Cloud Monitoring time series the alert layer can threshold against. Cheaper than streaming logs to a SIEM for this single use case.

### 7.5 Audit log sink + bucket (`google_logging_project_sink.audit`, `google_storage_bucket.audit_logs`)

- **Description.** A project-level log sink routing `cloudaudit.googleapis.com` plus compute/IAM/KMS events into a versioned GCS bucket with 1-day WORM retention and 400-day lifecycle delete.
- **Purpose.** Tamper-evident audit trail for compliance and incident forensics.
- **Why configured this way.**
  - **Sink at the project level.** Captures everything — admin activity, data access, IAM changes — in one stream.
  - **Versioning + 1-day WORM minimum retention.** The minimum retention is the tamper-evidence mechanism: an attacker who deletes a log can't actually erase it for at least a day, giving detection a window.
  - **400-day lifecycle delete.** Just over a year. Matches typical compliance retention requirements without paying for indefinite storage.
  - **GCS rather than BigQuery.** Cheap, immutable, exportable. BigQuery is the right backend for active log analytics; GCS is the right backend for "I need this 18 months from now for an audit."

### 7.6 Custom dashboard (`google_monitoring_dashboard.portal`)

- **Description.** A single dashboard with CPU / memory / disk / network panels for prod, CPU panel for DR, and LB request-rate panel.
- **Purpose.** Give an on-call operator a single URL that answers "what's going on right now?"
- **Why configured this way.** One dashboard, not ten. Operators under stress don't dig through dashboard hierarchies — they look at the one URL they bookmarked. Everything you need to triage an incident lives on one screen.

---

## 8. Bootstrap scripts (`scripts/mount-data-disk-*.sh`, `scripts/startup-*.sh`)

### 8.1 Two-file split — mount + provision

- **Description.** Each VM's `metadata_startup_script` is the concatenation of a `mount-data-disk-*.sh` (always runs) and a `startup-*.sh` (runs only if `var.run_startup_script = true`).
- **Purpose.** Decouple the always-required step (mounting the persistent data disk) from the optional step (provisioning the OS and PG).
- **Why configured this way.** When deploying from a fully-baked machine image (golden image with PG and nginx pre-installed), the provisioning step is unnecessary — but the data disk still needs mounting because it's a separate `google_compute_disk` that's never inside an image. Splitting the script lets you toggle off the provisioning while always running the mount.

### 8.2 `startup-prod.sh` — provisioning the prod VM

- **Description.** Installs Ops Agent, nginx, certbot (fallback), fail2ban, unattended-upgrades, PostgreSQL 16 from PGDG. Relocates the PG cluster to `/data/postgres/16/main` on the 2 TB SSD. Configures `pg_hba.conf` to accept `scram-sha-256` from the DR subnet only. Hardens SSH. Enables UFW with 22/80/443 to the world and 5432 to the DR CIDR only.
- **Purpose.** Take a stock Ubuntu image to "ready to serve traffic" without manual steps.
- **Why configured this way.**
  - **Idempotent.** Every step checks state before mutating. A re-run does not break a working system; it just confirms each step is already done. This is necessary for cloud-init style scripts because GCP's startup-script semantics don't guarantee single-run behaviour.
  - **PGDG repo for PG 16.** Ubuntu's default PG version lags. PGDG (PostgreSQL Global Development Group) provides current-major-version packages with security backports.
  - **Cluster relocation to `/data`.** The data disk is where the data lives; the boot disk is for the OS. Keeping the PG cluster on the boot disk defeats the whole point of having a separate data disk.
  - **`scram-sha-256` not `md5`.** SCRAM is the modern PG auth method; MD5 is end-of-life. Newer client libraries default to SCRAM; older ones need a config flag but work.
  - **UFW 5432 restricted to DR CIDR.** Even inside the firewall rules, defence in depth — UFW on the VM enforces the same restriction, so a misconfigured GCP firewall rule doesn't accidentally expose Postgres.

### 8.3 `startup-dr.sh` — provisioning the DR VM

- **Description.** Installs Ops Agent and PostgreSQL 16 server + client. Cluster data directory at `/backups/postgres/16/main`. Listens on localhost only.
- **Purpose.** Have a tested restore target for nightly dumps.
- **Why configured this way.** The DR VM never serves traffic, so `listen_addresses = 'localhost'` removes a whole class of attack surface and reduces the firewall rule needed. The server is present (not just the client) because a restore-validate cycle needs a running server to load the dump into. Validating the dump catches the "yes we have backups, no they don't actually restore" failure mode.

---

## 9. Cross-cutting design choices

A few decisions don't belong to any one component but shape the whole stack:

### 9.1 Why two VMs instead of a managed Cloud SQL HA pair?

The spec called for **daily SQL dumps with restore validation** — RPO of 24 hours, manual RTO. Cloud SQL with HA is an order of magnitude more expensive and the wrong abstraction for that requirement; it's optimised for synchronous replication and seconds-of-RPO. A small DR VM in a different zone meets the spec at roughly 1/10th the recurring cost. If the requirements later tighten (RPO < 1 hour, automated failover), migrating to Cloud SQL HA is the right move at that point.

### 9.2 Why google-managed SSL instead of certbot on the VM?

A managed cert removes a private key from the VM, removes the renewal cron job as a failure mode, and removes the need for the VM to be internet-reachable on port 80 for ACME challenges. We keep certbot installed on prod as a fallback in case the managed cert ever can't validate (DNS issue, edge case), but the primary path is managed.

### 9.3 Why `prevent_destroy` on the data disks and the backup vault?

The cost of a Terraform misclick on these resources is "we lost all customer data" or "we lost all audit evidence." `prevent_destroy` requires you to explicitly remove the lifecycle block before the resource can be destroyed — a one-commit speed bump that has caught real mistakes in real teams.

### 9.4 Why a separate state bucket per environment?

The bootstrap script creates a state bucket per project (`<project>-tfstate`). Separating state means a `terraform apply` against test cannot accidentally touch prod, no matter what tfvars file gets passed in. The blast radius is bounded by which backend you're init'd against.

### 9.5 Why is the WAF policy attached, but most cell-level customization left to defaults?

Cloud Armor preconfigured rules (sqli/xss/lfi/rfi/rce/scannerdetection) come with sensible signature weights tuned by Google's security team. Tuning per-rule sensitivity is something to do *after* observing real traffic for a few weeks — premature tuning produces false-positives or false-negatives based on assumptions, not data. The defaults are the right starting point.
