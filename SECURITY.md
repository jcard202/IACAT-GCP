# Security Guide

How this stack maps to the security requirements in the original procurement spec, and what you still need to operate.

---

## Spec → control mapping

| Requirement | Control | Where |
| --- | --- | --- |
| Public IP with SSL | Global HTTPS LB + Google-managed cert | `lb.tf` |
| Firewall rules | Custom VPC, deny-all default, tag-scoped allows | `firewall.tf` |
| Monitoring | Ops Agent + dashboard + alert policies | `monitoring.tf` + `scripts/startup-*.sh` |
| Web Application Firewall | Cloud Armor preconfigured OWASP CRS rules | `lb.tf` → `google_compute_security_policy.waf` |
| TLS 1.2 / 1.3 | `MODERN` SSL policy, `min_tls_version = TLS_1_2` | `lb.tf` → `google_compute_ssl_policy.modern` |
| Secure cookies | App-layer concern — set `Secure; HttpOnly; SameSite=Lax` in your app | (your app) |
| HSTS | `Strict-Transport-Security` header at LB + nginx | `lb.tf` `custom_response_headers` + `scripts/startup-prod.sh` |
| DDoS protection | Cloud Armor adaptive protection + per-IP rate-based ban | `lb.tf` |
| Audit logging | Project sink → versioned WORM GCS bucket | `monitoring.tf` → `google_logging_project_sink.audit` |
| Vulnerability scans | Shielded VM + unattended-upgrades + recommended Security Command Center Premium | `compute.tf` + `scripts/startup-*.sh` |

---

## Network posture

- **No default VPC.** Custom VPC means no implicit public exposure.
- **No public IP on the DR VM.** Egress via Cloud NAT, ingress via IAP only.
- **No public SSH on either VM.** Port 22 is allowed only from Google's IAP range (`35.235.240.0/20`).
- **VPC Flow Logs** at 50% sampling on both subnets — forensic record of all packet flows.
- **Deny-all explicit rule** at priority 65534 ensures any future allow-rule mistake leaves the rest of the surface closed and *logged*.

---

## Identity & access

### VM identities

Both VMs run as **dedicated service accounts** (`protectportal-prod-vm`, `protectportal-dr-vm`) with only the roles needed by the Ops Agent and Artifact Registry. No `roles/owner`, no `roles/editor`.

If your app needs to access Cloud Storage, Cloud SQL, or Secret Manager, add narrowly-scoped role bindings to the VM service account — do not reuse the default Compute Engine SA.

### Human access

- **OS Login enforced** (`enable-oslogin = TRUE`) — every SSH session is tied to a Google identity, not a shared key.
- **Project SSH keys blocked** (`block-project-ssh-keys = TRUE`) — legacy project-wide keys can't bypass OS Login.
- **Serial port disabled** (`serial-port-enable = FALSE`) — closes the alternate Google-mediated console.

Required roles per engineer:

| Role | Why |
| --- | --- |
| `roles/iap.tunnelResourceAccessor` | Permission to open the IAP tunnel to a VM |
| `roles/compute.osLogin` | Login as a non-sudo user |
| `roles/compute.osAdminLogin` | Login with sudo (grant sparingly) |

---

## Edge security (LB + Cloud Armor)

### TLS

- `min_tls_version = TLS_1_2`
- `profile = MODERN` — TLS 1.3 negotiated when client supports it
- Google-managed cert auto-renews ~30 days before expiry

If a compliance auditor asks "do you support TLS 1.0/1.1?", the answer is **no** — the SSL policy rejects the handshake.

### Cloud Armor rules

| Priority | Action | What it blocks |
| --- | --- | --- |
| 1000 | deny 403 | SQL injection (OWASP `sqli-v33-stable`) |
| 1001 | deny 403 | XSS (`xss-v33-stable`) |
| 1002 | deny 403 | Local file inclusion (`lfi-v33-stable`) |
| 1003 | deny 403 | Remote file inclusion (`rfi-v33-stable`) |
| 1004 | deny 403 | Remote code execution (`rce-v33-stable`) |
| 1005 | deny 403 | Known vulnerability scanners (`scannerdetection-v33-stable`) |
| 2000 | rate-based ban | >600 requests / 60 s from a single IP → 5-minute ban |
| 2147483647 | allow | Default — anything not matched above |

**Adaptive Protection** is enabled — Cloud Armor uses ML to detect anomalous L7 traffic patterns and surface DDoS attacks as security findings. It does not auto-block by default; review findings under `Security → Cloud Armor → Adaptive Protection`.

### Response headers

Set at the LB so even a buggy backend can't strip them:

```
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
```

The `max-age=63072000` is two years — required for HSTS preload list submission.

---

## VM hardening

### Shielded VM

Both VMs run with:
- **Secure Boot** — only signed kernel modules load.
- **vTPM** — integrity-measured boot, supports remote attestation.
- **Integrity Monitoring** — Cloud Monitoring receives boot integrity reports; alert if they fail.

### OS-level

`scripts/startup-prod.sh` and `scripts/startup-dr.sh` configure:
- `PasswordAuthentication no`, `PermitRootLogin no` — keys only, no root login.
- `unattended-upgrades` enabled — security patches install automatically.
- `fail2ban` — bans IPs with repeated SSH failures (belt-and-suspenders alongside IAP).
- `ufw` — host firewall denying all ingress except the application ports.

---

## Audit logging

- **Cloud Audit Logs** (Admin Activity, System Event, Data Access for Compute/IAM/KMS) flow into a project sink → versioned GCS bucket.
- The bucket has **`uniform_bucket_level_access`** and **`public_access_prevention = enforced`** — no object can ever be made public.
- **1-day WORM retention** prevents same-day deletion of audit objects (raise this if your compliance regime requires longer).
- **400-day lifecycle delete** ages out old logs to control cost.

Bucket name: `terraform output audit_log_bucket`.

### Compliance retention

If you need 7-year retention (e.g. for financial-sector compliance), set the bucket's `retention_policy.retention_period` to `220752000` (7 × 365.25 × 86400) and remove the 400-day lifecycle rule.

---

## Vulnerability scanning

The stack enables the foundations; you still need to **turn on Security Command Center** at the org level:

```bash
# One-time, by an Org Admin
gcloud scc settings update --organization=YOUR_ORG_ID \
  --tier=PREMIUM
```

Premium tier provides:
- **Container & VM scanning** for known CVEs
- **Web Security Scanner** for the live load balancer endpoint
- **Sensitive Data Protection** (DLP) findings

Without Premium, the stack still runs `unattended-upgrades` on each VM (apt security patches) and Shielded VM integrity monitoring — but you have no centralised CVE dashboard.

---

## Secrets management

This Terraform does **not** create or manage application secrets (DB passwords, API keys). Recommended:

1. Create secrets in **Secret Manager**:
   ```bash
   echo -n "supersecret" | gcloud secrets create portal-db-password --data-file=-
   ```
2. Grant the prod VM service account read access:
   ```bash
   gcloud secrets add-iam-policy-binding portal-db-password \
     --member="serviceAccount:protectportal-prod-vm@YOUR_PROJECT.iam.gserviceaccount.com" \
     --role="roles/secretmanager.secretAccessor"
   ```
3. Fetch at app startup:
   ```bash
   gcloud secrets versions access latest --secret=portal-db-password
   ```

Rotate by `gcloud secrets versions add` and reading `latest` in the app. Never put secrets in `terraform.tfvars` (it's `.gitignore`'d, but still ends up in plain-text `terraform.tfstate`).

---

## Key rotation

| Key / credential | Rotation |
| --- | --- |
| Google-managed SSL cert | Automatic, ~30 days before expiry |
| OS Login SSH keys | Per-user — `gcloud compute os-login ssh-keys remove` |
| VM service account keys | None issued — uses metadata-server tokens |
| Application secrets in Secret Manager | Manual / scripted — add a new version, app reads `latest` |
| Terraform state bucket access | Limit to the IAM identity running `terraform apply` |

---

## Incident response quick reference

| Scenario | First action |
| --- | --- |
| Suspected DDoS | Check `Security → Cloud Armor → Adaptive Protection` for findings. Tighten the rate-based ban from 600 → 100 req/min if abuse is confirmed. |
| Suspected RCE / web compromise | `gcloud compute instances stop protectportal-prod` to freeze. Snapshot the boot disk before any other action — that's your forensic copy. |
| Credential leak | Revoke the leaked IAM binding immediately. Audit `gcloud logging read 'protoPayload.authenticationInfo.principalEmail="leaked-account"'` for what they did. |
| SSL cert expiring | Shouldn't happen (managed) — but if it does, `gcloud compute ssl-certificates describe protectportal-managed-cert --global` and look at `managed.status` / `managed.domainStatus`. |
| Audit log tamper attempt | The sink writer SA has only `roles/storage.objectCreator` — it cannot delete or overwrite. Tamper attempts surface as `permissions denied` in audit logs. |

---

## What this stack does **not** cover

- **Cloud SQL or managed database** — the prod VM hosts the DB itself per spec. For higher availability move to Cloud SQL HA.
- **Multi-region failover** — DR is same-region, different-zone. For region-level disaster recovery, replicate snapshots cross-region (`gcloud compute snapshots create --storage-location=us-central1`).
- **Application-layer secrets** — wire up Secret Manager in your app (see above).
- **CI/CD pipeline** — Terraform here assumes local apply or a manually-triggered pipeline. Wire to Cloud Build / GitHub Actions separately.
- **VPC Service Controls** — out of scope unless you have an org-level perimeter requirement.
