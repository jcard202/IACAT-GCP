# Enabling HTTPS on Test and Production

End-to-end procedure to bring up Google-managed SSL for **both** the test deploy (`iacat-test.quanbyit.com`) and a production deploy (`iacat.quanbyit.com`), with DNS records at GoDaddy.

The Terraform already creates everything cert-related when `enable_https = true`. You only need to:
1. Reserve the LB IP (happens automatically on first `apply`).
2. Add an A record at GoDaddy pointing the domain at that IP.
3. Wait for DNS to propagate.
4. Re-apply with `enable_https = true`.
5. Wait 15–60 minutes for Google to issue the cert.

---

## Environment inventory

| | Test | Production |
| --- | --- | --- |
| **GCP project** | `iacat-test` | `iacat-prod` *(new)* |
| **State bucket** | `gs://iacat-test-tfstate` | `gs://iacat-prod-tfstate` |
| **State prefix** | `protectportal/test` | `protectportal/prod` |
| **Domain** | `iacat-test.quanbyit.com` | `iacat.quanbyit.com` |
| **tfvars file** | `test.tfvars` | `prod.tfvars` |
| **`name_prefix`** | `ppt-test` | `protectportal` |
| **Sizing** | `e2-micro`, 10 GB disks | `n2-standard-16`, 2 TB SSD |
| **Cost / month** | ~$42 | ~$1100 |

Both environments use the same Terraform code in this directory. You switch between them by re-initialising with a different `-backend-config` and applying with a different `-var-file`.

---

## Part 1 — Test (`iacat-test.quanbyit.com`)

Assumes the test stack is currently destroyed (or you're starting fresh after the earlier teardown).

### 1.1 Init against the test state

```powershell
terraform init -reconfigure `
    -backend-config="bucket=iacat-test-tfstate" `
    -backend-config="prefix=protectportal/test"
```

### 1.2 First apply with HTTPS OFF (reserves the LB IP)

`test.tfvars` ships with `enable_https = false`. Leave it for the first apply so the IP is reserved before we touch DNS.

```powershell
terraform apply -var-file test.tfvars -auto-approve
terraform output -raw load_balancer_ip
```

Note that IP — you need it in the next step. The `google_compute_global_address.lb_ip` resource holds onto it across re-applies.

### 1.3 Add the GoDaddy A record for test

1. Sign in at <https://account.godaddy.com>.
2. **My Products** → `quanbyit.com` → **DNS**.
3. **Records** → **Add New Record**:

   | Field | Value |
   | --- | --- |
   | Type | `A` |
   | Name | `iacat-test` |
   | Value | *the IP from step 1.2* |
   | TTL | `600 seconds` |

4. Save.

### 1.4 Wait for DNS

```powershell
$lbIp = terraform output -raw load_balancer_ip
while ($true) {
    $resolved = (Resolve-DnsName iacat-test.quanbyit.com -Type A -Server 8.8.8.8 -ErrorAction SilentlyContinue).IPAddress
    if ($resolved -eq $lbIp) { Write-Host "DNS ready: $resolved" -ForegroundColor Green; break }
    Write-Host "$(Get-Date -Format HH:mm:ss) waiting (got: $resolved)" -ForegroundColor Yellow
    Start-Sleep 30
}
```

### 1.5 Flip HTTPS on and re-apply

Edit `test.tfvars` and change:

```hcl
enable_https = true
```

Then:

```powershell
terraform apply -var-file test.tfvars -auto-approve
```

This adds the managed cert, SSL policy, HTTPS proxy, HTTPS forwarding rule, and swaps the HTTP forwarding rule to redirect to HTTPS.

### 1.6 Wait for the cert to go ACTIVE

```powershell
while ($true) {
    $status = gcloud compute ssl-certificates describe ppt-test-managed-cert --global `
        --format="value(managed.status,managed.domainStatus)"
    Write-Host "$(Get-Date -Format HH:mm:ss) $status"
    if ($status -match "^ACTIVE\s+iacat-test\.quanbyit\.com=ACTIVE") { break }
    Start-Sleep 60
}
```

### 1.7 Verify TLS

```powershell
curl.exe -sI "https://iacat-test.quanbyit.com/" | Select-Object -First 6
```

Expect `HTTP/2 200` and the HSTS / security headers.

---

## Part 2 — Production (`iacat.quanbyit.com`)

### 2.1 Create the production GCP project

```powershell
# One-time
gcloud projects create iacat-prod --name="IACAT Production"
```

Then **link a billing account** at the Console — GCP refuses to enable APIs without it:

<https://console.cloud.google.com/billing/linkedaccount?project=iacat-prod>

### 2.2 Bootstrap the production project

```powershell
.\scripts\bootstrap.ps1 -ProjectId iacat-prod
```

This enables the APIs and creates `gs://iacat-prod-tfstate` with versioning + uniform access. It also writes `.env.gcp.ps1` at the repo root — but this overwrites the test one. **Don't rely on `.env.gcp.ps1` to stay env-stable** — always be explicit about `-backend-config` and `-var-file`.

### 2.3 Create `prod.tfvars`

```powershell
Copy-Item prod.tfvars.example prod.tfvars
notepad prod.tfvars
```

The template already has the right values for `iacat-prod` / `iacat.quanbyit.com` / `devops@quanbyit.com`. Just verify before saving.

### 2.4 Switch Terraform state to production

> **This is the operation that's most prone to mistakes.** It changes which environment your `terraform apply` will target. Be deliberate.

```powershell
terraform init -reconfigure `
    -backend-config="bucket=iacat-prod-tfstate" `
    -backend-config="prefix=protectportal/prod"
```

Confirm with:

```powershell
terraform state list
```

The list should be **empty** on the very first prod init. If you see test resources, you initialised against the wrong backend — go back to 2.4 and re-run.

### 2.5 First apply with HTTPS OFF (reserves the prod LB IP)

Temporarily disable HTTPS so you can reserve the IP before configuring DNS. Add this one line to the top of `prod.tfvars` (or pass on the command line):

```hcl
enable_https = false
```

Then:

```powershell
terraform plan -var-file prod.tfvars -out tfplan
```

**Read the plan carefully.** Expect ~40 resources to add. Confirm:
- `machine_type = "n2-standard-16"`
- `size = 2048` on the prod data disk
- `name = "protectportal-prod"` (not `ppt-test-prod`)
- `deletion_protection = true`

```powershell
terraform apply tfplan
terraform output -raw load_balancer_ip
```

Production apply takes 8–12 minutes (bigger VMs, more provisioning). Note the IP.

### 2.6 Add the GoDaddy A record for production

In GoDaddy → `quanbyit.com` DNS → **Add New Record**:

| Field | Value |
| --- | --- |
| Type | `A` |
| Name | `iacat` |
| Value | *prod LB IP from 2.5* |
| TTL | `600 seconds` |

Save.

### 2.7 Wait for DNS

```powershell
$lbIp = terraform output -raw load_balancer_ip
while ($true) {
    $resolved = (Resolve-DnsName iacat.quanbyit.com -Type A -Server 8.8.8.8 -ErrorAction SilentlyContinue).IPAddress
    if ($resolved -eq $lbIp) { Write-Host "DNS ready: $resolved" -ForegroundColor Green; break }
    Write-Host "$(Get-Date -Format HH:mm:ss) waiting (got: $resolved)" -ForegroundColor Yellow
    Start-Sleep 30
}
```

### 2.8 Flip HTTPS on for production

Remove the `enable_https = false` override from `prod.tfvars` (or set it to `true` — `true` is the default so removing the line works too).

```powershell
terraform apply -var-file prod.tfvars -auto-approve
```

### 2.9 Wait for the production cert

```powershell
while ($true) {
    $status = gcloud compute ssl-certificates describe protectportal-managed-cert --global `
        --project=iacat-prod `
        --format="value(managed.status,managed.domainStatus)"
    Write-Host "$(Get-Date -Format HH:mm:ss) $status"
    if ($status -match "^ACTIVE\s+iacat\.quanbyit\.com=ACTIVE") { break }
    Start-Sleep 60
}
```

### 2.10 Verify production TLS

```powershell
curl.exe -sI "https://iacat.quanbyit.com/" | Select-Object -First 6
```

Once you see `HTTP/2 200` and HSTS, production is live.

---

## Switching between environments later

The two state prefixes live in two state buckets. To switch:

**Work on test:**
```powershell
terraform init -reconfigure `
    -backend-config="bucket=iacat-test-tfstate" `
    -backend-config="prefix=protectportal/test"

terraform apply -var-file test.tfvars
```

**Work on production:**
```powershell
terraform init -reconfigure `
    -backend-config="bucket=iacat-prod-tfstate" `
    -backend-config="prefix=protectportal/prod"

terraform apply -var-file prod.tfvars
```

> **Discipline:** always run `terraform state list` immediately after `init -reconfigure` and confirm you see the expected env's resources (or empty for first-time init). One mis-routed `terraform apply` against the wrong backend can destroy production.

For a more robust setup once both environments are stable, consider [Terraform workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces) or separate working directories per environment.

---

## DNS quick reference (GoDaddy)

| Domain | Record type | Name | Value |
| --- | --- | --- | --- |
| `iacat-test.quanbyit.com` | A | `iacat-test` | LB IP from test deploy |
| `iacat.quanbyit.com` | A | `iacat` | LB IP from prod deploy |

> In GoDaddy's UI, the **Name** field is just the subdomain. Don't type the full FQDN — GoDaddy appends `.quanbyit.com` automatically.

---

## Cost note

Production runs ~$1100 / month. Before pulling the trigger on Part 2:

- Apply 1- or 3-year **committed-use discounts** in GCP Billing → Committed-use discounts after running for a few weeks (~30% / ~50% off the compute line).
- The 2 TB `pd-ssd` data disk is ~$340 / month. If the workload is read-light, `prod_data_disk_type = "pd-balanced"` cuts that ~40%.

---

## Troubleshooting

See the same section in [TESTING.md](TESTING.md#troubleshooting) for issues common to both environments. Production-specific issues:

| Symptom | Fix |
| --- | --- |
| `quotaExceeded: N2_CPUS` in production region | <https://console.cloud.google.com/iam-admin/quotas?project=iacat-prod> → request 20+ for `N2_CPUS` in `asia-southeast1` |
| You accidentally ran `terraform apply` against the wrong env | If nothing changed (plan said `No changes`), no harm done. If resources were modified, **stop**, re-init against the correct backend, and investigate `terraform.tfstate` in the GCS bucket — versioning is enabled, so you can roll back via `gcloud storage cp` from a prior version. |
| State drift between what's in GCS and what Terraform thinks | `terraform refresh -var-file <env>.tfvars` to re-read all resources from GCP. |
