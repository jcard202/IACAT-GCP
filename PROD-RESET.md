# Production Environment Reset Procedure

> # ⚠️ THIS DESTROYS PRODUCTION
>
> Everything in `protectportal-498318` that this Terraform manages — the prod VM, the DR VM, the **2 TB data disk**, the load balancer, the public IP, the SSL certificate, the audit log bucket — gets deleted and recreated from scratch.
>
> **Before running this:** make sure you have a recent snapshot of the production data disk *and* a tested restore procedure. Once `terraform state rm google_compute_disk.prod_data` runs followed by `gcloud compute disks delete`, the 2 TB of customer data is **gone**. Snapshots from the daily schedule are your only recovery path.

End-to-end teardown of the `protectportal-498318` deploy followed by a fresh rebuild. Use **only** for full-environment reset scenarios — major architectural change, compliance-driven rebuild, recovery from a catastrophically broken state. For routine config drift, prefer targeted `-replace` or in-place updates.

Procedure handles all three deployment paths the stack supports (default Ubuntu, disk image, machine image). The state-rm step lists resources for **all** paths — the ones that don't exist for your current deploy report "Not in state" and are skipped.

---

## 0. Pre-flight — do NOT skip these

### 0.1 Stakeholder communication

Production downtime during this procedure is **~60-90 minutes** end to end:
- 5-10 min teardown
- 10-15 min rebuild (more if the SSL cert needs to re-validate)
- 15-60 min waiting for the new Google-managed SSL certificate to flip to `ACTIVE` after the new LB IP propagates through DNS
- 5-10 min mount + verification

Notify stakeholders. Schedule for an off-hours maintenance window. Update your status page.

### 0.2 Confirm a recent snapshot exists

```powershell
gcloud compute snapshots list --project=protectportal-498318 `
    --filter="sourceDisk~'protectportal-prod-data'" `
    --sort-by=~creationTimestamp `
    --limit=3 `
    --format="table(name,creationTimestamp,diskSizeGb,status)"
```

You should see at least one `READY` snapshot dated within the last 24 hours (assuming `enable_snapshot_schedule = true` in `prod.tfvars`). If the most recent snapshot is older than 24 hours **stop** — investigate why the schedule isn't firing before you touch anything.

### 0.3 Take an explicit, named pre-reset snapshot

In addition to the scheduled snapshots, take one right now and name it so you can find it after the rebuild:

```powershell
$timestamp = Get-Date -Format "yyyyMMddHHmm"
gcloud compute disks snapshot protectportal-prod-data `
    --project=protectportal-498318 `
    --zone=asia-southeast1-a `
    --snapshot-names="protectportal-prod-data-pre-reset-$timestamp" `
    --storage-location=asia-southeast1

gcloud compute disks snapshot protectportal-dr-data `
    --project=protectportal-498318 `
    --zone=asia-southeast1-b `
    --snapshot-names="protectportal-dr-data-pre-reset-$timestamp" `
    --storage-location=asia-southeast1
```

These survive the destroy (snapshots are independent resources) and give you a guaranteed-known-recent restore point.

### 0.4 GoDaddy DNS access ready

The new deploy gets a **new** global LB IP. You'll need to update the A record at GoDaddy for `iacat.quanbyit.com` (or whatever production domain you're using). Have the GoDaddy admin login ready — see [HTTPS-SETUP.md](HTTPS-SETUP.md) Step 2.6 for the click path.

### 0.5 Auth + backend pointed at PRODUCTION

```powershell
gcloud auth list --filter="status:ACTIVE" --format="value(account)"
Test-Path "$env:APPDATA\gcloud\application_default_credentials.json"

# Source the prod env helper
. .\.env.gcp.ps1

# Make sure the backend points at PRODUCTION state
terraform init -reconfigure `
    -backend-config="bucket=protectportal-498318-tfstate" `
    -backend-config="prefix=protectportal/prod"

# Confirm we're on the prod state — should list prod resources
terraform state list | Select-Object -First 5
```

If `terraform state list` shows `ppt-test-*` resources, you initialised against the test bucket — **stop**, re-run the init with the prod backend-config before going any further.

---

## 1. Disable production safety guards

Both VMs have `deletion_protection = true` (per `prod.tfvars`). Terraform refuses to delete protected instances even with `terraform destroy`. Disable them first:

```powershell
gcloud compute instances update protectportal-prod `
    --zone=asia-southeast1-a `
    --project=protectportal-498318 `
    --no-deletion-protection

gcloud compute instances update protectportal-dr `
    --zone=asia-southeast1-b `
    --project=protectportal-498318 `
    --no-deletion-protection
```

These two API calls don't take down the VMs — they just toggle the deletion-protection flag.

---

## 2. Teardown

### Step 2.1 — First destroy attempt (fails on `prevent_destroy`)

```powershell
terraform destroy -var-file prod.tfvars -auto-approve
```

Fails at plan time on:
```
Resource google_compute_disk.prod_data has lifecycle.prevent_destroy set ...
Resource google_compute_disk.dr_data has lifecycle.prevent_destroy set ...
```

### Step 2.2 — State-rm the disks + their attached_disk bindings

```powershell
terraform state rm `
    google_compute_disk.prod_data `
    google_compute_disk.dr_data `
    'google_compute_attached_disk.prod_data[0]' `
    'google_compute_attached_disk.dr_data[0]'
```

The last two entries only exist if your deploy used machine images. The command prints `Not in state` for whatever isn't present and continues — harmless.

### Step 2.3 — Second destroy (gets through VMs, network, monitoring)

```powershell
terraform destroy -var-file prod.tfvars -auto-approve
```

This pass tears down everything except the audit bucket and `random_id.audit_suffix`. Fails at the end on:

```
Error: Error trying to delete bucket protectportal-498318-protectportal-audit-XXXXXXXX
containing objects without `force_destroy` set to true
```

### Step 2.4 — Decide: keep the audit logs or destroy?

**Production audit logs have compliance weight.** Two options:

**Option A — KEEP them (recommended for prod):**

State-rm the bucket from Terraform's awareness; the bucket stays in GCP, owned by the project, untouched:

```powershell
terraform state rm google_storage_bucket.audit_logs google_logging_project_sink.audit
```

After the rebuild, the new deploy creates a **new** audit bucket (random suffix in the name). The old one persists in `protectportal-498318` for as long as you want; rename it for clarity:

```powershell
# The old bucket name — substitute the actual random suffix from your list
gcloud storage buckets list --project=protectportal-498318 `
    --filter="name~'protectportal-audit'" --format="value(name)"
```

**Option B — DESTROY them (only if you have approval to discard production audit history):**

Empty the bucket manually via Console:

```powershell
Start-Process "https://console.cloud.google.com/storage/browser?project=protectportal-498318"
Read-Host "Empty + delete the audit bucket in Console, then press Enter"
```

### Step 2.5 — Third destroy (cleans the last resources)

```powershell
terraform destroy -var-file prod.tfvars -auto-approve
```

Sweeps the `random_id.audit_suffix` and (if you chose Option B) the audit bucket.

### Step 2.6 — Delete the orphaned data disks

```powershell
gcloud compute disks delete protectportal-prod-data `
    --zone=asia-southeast1-a --project=protectportal-498318 --quiet

gcloud compute disks delete protectportal-dr-data `
    --zone=asia-southeast1-b --project=protectportal-498318 --quiet
```

**This is the irreversible step.** Your 2 TB of production data is gone after this command completes. The pre-reset snapshots from Step 0.3 are now your only copy.

---

## 3. Verify clean

```powershell
Write-Host "Instances:        $((gcloud compute instances list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Disks:            $((gcloud compute disks list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Networks (custom):$((gcloud compute networks list --project=protectportal-498318 --filter='name!=default' --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Reserved IPs:     $((gcloud compute addresses list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Forwarding rules: $((gcloud compute forwarding-rules list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Custom SAs:       $((gcloud iam service-accounts list --project=protectportal-498318 --filter='email~protectportal' --format='value(email)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Snapshots:        $((gcloud compute snapshots list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines) (the pre-reset snapshots should still be here)"
Write-Host "Storage buckets:  $((gcloud storage buckets list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines) (tfstate bucket + possibly old audit bucket)"
Write-Host "Machine images:   $((gcloud beta compute machine-images list --project=protectportal-498318 --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Disk images:      $((gcloud compute images list --project=protectportal-498318 --no-standard-images --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Terraform state:  $((terraform state list 2>&1 | Measure-Object -Line).Lines) resources"
```

Expected:

| Counter | Value | Note |
| --- | --- | --- |
| Instances | 0 | |
| Disks | 0 | |
| Networks (custom) | 0 | `default` VPC is GCP's built-in, untouched |
| Reserved IPs | 0 | LB IP gone (new one comes back on rebuild) |
| Forwarding rules | 0 | |
| Custom SAs | 0 | `protectportal-prod-vm`, `protectportal-dr-vm` released |
| Snapshots | 2 (from pre-reset) + any retained schedule snapshots | These are your recovery path; **don't delete** until the rebuild is verified |
| Storage buckets | 1-2 | `protectportal-498318-tfstate` (always) + the old audit bucket if you chose Option A in 2.4 |
| Machine images | 0 or N | Whatever you built / inherited |
| Disk images | 0 or N | Same |
| Terraform state | 0 resources | |

---

## 4. Rebuild

```powershell
# (Still sourced from .env.gcp.prod.ps1, still init'd against prod backend)
terraform plan -var-file prod.tfvars -out tfplan
terraform apply tfplan
```

Plan should show **~40 resources to add, 0 to change, 0 to destroy**. Apply runs 10-15 minutes (production sizing has longer VM startup than test).

> **Expected hiccup near the end of the apply** — the `google_monitoring_alert_policy.ssh_brute_force` resource often fails with:
>
> ```
> Error 404: Cannot find metric(s) that match type =
> "logging.googleapis.com/user/protectportal/failed_ssh_attempts".
> If a metric was created recently, it could take up to 10 minutes to become available.
> ```
>
> This is a Cloud Logging → Cloud Monitoring metric-catalog propagation race. The log-based metric was created earlier in the same apply, and the alert policy references it before Monitoring has indexed it. **Just re-run the apply** — the metric is usually there within 30-90 seconds. Most apply runs only need one retry; if it still fails after 10 minutes, look for a Monitoring API quota issue rather than waiting longer.
>
> ```powershell
> terraform plan -var-file prod.tfvars -out tfplan
> terraform apply tfplan
> ```
>
> Plan: **1 to add, 0 to change, 0 to destroy**.

Which image path runs depends on what's currently set in `prod.tfvars`:

| `prod.tfvars` setting | Path |
| --- | --- |
| `shared_image = "..."` | Both VMs from that disk image |
| `prod_disk_image` and/or `dr_disk_image` | Per-VM disk image |
| `prod_machine_image` and/or `dr_machine_image` | Per-VM machine image |
| Nothing of the above uncommented | Default Ubuntu LTS — then the full startup script runs |

---

## 5. Mount kick (only when using machine images with `*_create_data_disk = true`)

If you're using a machine image AND have Terraform attach our managed data disk via `google_compute_attached_disk`, the disk attaches a few seconds after the VM boots — the startup script's 30-second wait usually catches it but re-running the mount script is the safe move:

```powershell
foreach ($pair in @(@{Vm='protectportal-prod';Zone='asia-southeast1-a';Script='mount-data-disk-prod.sh'},
                    @{Vm='protectportal-dr';  Zone='asia-southeast1-b';Script='mount-data-disk-dr.sh'})) {
    Write-Host "=== $($pair.Vm) ===" -ForegroundColor Cyan
    gcloud compute scp "scripts\$($pair.Script)" "$($pair.Vm):/tmp/$($pair.Script)" `
        --tunnel-through-iap --zone=$pair.Zone --project=protectportal-498318
    gcloud compute ssh $pair.Vm --tunnel-through-iap --zone=$pair.Zone --project=protectportal-498318 `
        --command="sudo bash /tmp/$($pair.Script)"
}
```

Skip this if:
- The MI carries its own data disk (`*_create_data_disk = false`)
- You're using a disk image or default Ubuntu (the data disk attaches in the same API call as the VM, no race)

---

## 6. Restore data from the pre-reset snapshot

If you want the previous data back on the new data disk:

```powershell
$snap = "protectportal-prod-data-pre-reset-<TIMESTAMP>"

# Create a temporary disk from the snapshot
gcloud compute disks create protectportal-prod-data-restored `
    --project=protectportal-498318 `
    --zone=asia-southeast1-a `
    --source-snapshot=$snap `
    --type=pd-ssd

# Stop the new prod VM
gcloud compute instances stop protectportal-prod `
    --zone=asia-southeast1-a --project=protectportal-498318

# Detach the new (empty) data disk
gcloud compute instances detach-disk protectportal-prod `
    --disk=protectportal-prod-data `
    --zone=asia-southeast1-a --project=protectportal-498318

# Attach the restored disk in its place (same device name so the mount path works)
gcloud compute instances attach-disk protectportal-prod `
    --disk=protectportal-prod-data-restored `
    --device-name=protectportal-prod-data `
    --zone=asia-southeast1-a --project=protectportal-498318

# Start the VM
gcloud compute instances start protectportal-prod `
    --zone=asia-southeast1-a --project=protectportal-498318
```

Repeat with the DR snapshot if you also want to restore the DR side.

After Terraform sees the disk rename, you'll need to update state — `terraform state rm google_compute_disk.prod_data` then `terraform import google_compute_disk.prod_data projects/protectportal-498318/zones/asia-southeast1-a/disks/protectportal-prod-data-restored`.

> **If you're doing a clean-slate rebuild** (no data restore — the rebuild starts fresh), skip this section entirely.

---

## 7. Update DNS

The new global LB IP is different from the old one. Get it:

```powershell
$newIp = terraform output -raw load_balancer_ip
Write-Host "New LB IP: $newIp" -ForegroundColor Yellow
Write-Host "Update GoDaddy A record for iacat.quanbyit.com -> $newIp"
```

Then in GoDaddy: <https://account.godaddy.com> → My Products → `quanbyit.com` → DNS → edit the `iacat` A record → set Value to the new IP → TTL `600` → Save.

Poll until your DNS provider has propagated:

```powershell
while ($true) {
    $resolved = (Resolve-DnsName iacat.quanbyit.com -Type A -Server 8.8.8.8 -ErrorAction SilentlyContinue).IPAddress
    if ($resolved -eq $newIp) { Write-Host "DNS ready: $resolved" -ForegroundColor Green; break }
    Write-Host "$(Get-Date -Format HH:mm:ss) waiting (got: $resolved)" -ForegroundColor Yellow
    Start-Sleep 30
}
```

---

## 8. Wait for the Google-managed SSL cert

Once DNS resolves to the new IP, the cert starts validating automatically:

```powershell
while ($true) {
    $status = gcloud compute ssl-certificates describe protectportal-managed-cert --global `
        --project=protectportal-498318 `
        --format="value(managed.status,managed.domainStatus)"
    Write-Host "$(Get-Date -Format HH:mm:ss) $status"
    if ($status -match "^ACTIVE\s+iacat\.quanbyit\.com=ACTIVE") { break }
    Start-Sleep 60
}
Write-Host "Certificate is ACTIVE." -ForegroundColor Green
```

Typical: 15-30 min. First-issuance certs sometimes take up to an hour.

---

## 9. Verify

```powershell
# HTTPS end-to-end
curl.exe -sI "https://iacat.quanbyit.com/" | Select-Object -First 6

# Backend health
gcloud compute backend-services get-health protectportal-backend `
    --global --project=protectportal-498318

# Both VMs RUNNING
gcloud compute instances list --project=protectportal-498318 `
    --filter="labels.role:protectportal" `
    --format="table(name,zone.basename(),status,machineType.basename())"

# Mounts persisted
foreach ($pair in @(@{Vm='protectportal-prod';Zone='asia-southeast1-a';Mount='/data'},
                    @{Vm='protectportal-dr';  Zone='asia-southeast1-b';Mount='/backups'})) {
    Write-Host "=== $($pair.Vm) ===" -ForegroundColor Cyan
    gcloud compute ssh $pair.Vm --tunnel-through-iap --zone=$pair.Zone --project=protectportal-498318 `
        --command="df -hT $($pair.Mount); grep $($pair.Mount) /etc/fstab"
}
```

Run the full UAT walkthrough in [SPEC-VERIFICATION.md](SPEC-VERIFICATION.md) — set `$env:PROJECT = "protectportal-498318"`, `$env:NAME_PREFIX = "protectportal"`, `$env:DOMAIN = "iacat.quanbyit.com"` at the top.

---

## 10. Once verified, clean up the pre-reset snapshots

Keep them for a few days after the rebuild is verified and the application is operating normally, then:

```powershell
gcloud compute snapshots delete `
    protectportal-prod-data-pre-reset-<TIMESTAMP> `
    protectportal-dr-data-pre-reset-<TIMESTAMP> `
    --project=protectportal-498318 --quiet
```

Daily-scheduled snapshots continue under the normal retention policy.

---

## TL;DR one-block copy-paste (for the cool-headed)

```powershell
# === PRE-FLIGHT ===
$timestamp = Get-Date -Format "yyyyMMddHHmm"
gcloud compute disks snapshot protectportal-prod-data `
    --project=protectportal-498318 --zone=asia-southeast1-a `
    --snapshot-names="protectportal-prod-data-pre-reset-$timestamp" `
    --storage-location=asia-southeast1
gcloud compute disks snapshot protectportal-dr-data `
    --project=protectportal-498318 --zone=asia-southeast1-b `
    --snapshot-names="protectportal-dr-data-pre-reset-$timestamp" `
    --storage-location=asia-southeast1

. .\.env.gcp.prod.ps1
terraform init -reconfigure `
    -backend-config="bucket=protectportal-498318-tfstate" `
    -backend-config="prefix=protectportal/prod"

# === DISABLE DELETION PROTECTION ===
gcloud compute instances update protectportal-prod --zone=asia-southeast1-a --project=protectportal-498318 --no-deletion-protection
gcloud compute instances update protectportal-dr   --zone=asia-southeast1-b --project=protectportal-498318 --no-deletion-protection

# === TEARDOWN ===
terraform destroy -var-file prod.tfvars -auto-approve
terraform state rm `
    google_compute_disk.prod_data `
    google_compute_disk.dr_data `
    'google_compute_attached_disk.prod_data[0]' `
    'google_compute_attached_disk.dr_data[0]'
terraform destroy -var-file prod.tfvars -auto-approve

# Choose: keep audit bucket (Option A) ...
terraform state rm google_storage_bucket.audit_logs google_logging_project_sink.audit
# ... or destroy it (Option B) -- manually empty in Console first
# Start-Process "https://console.cloud.google.com/storage/browser?project=protectportal-498318"

terraform destroy -var-file prod.tfvars -auto-approve

gcloud compute disks delete protectportal-prod-data --zone=asia-southeast1-a --project=protectportal-498318 --quiet
gcloud compute disks delete protectportal-dr-data   --zone=asia-southeast1-b --project=protectportal-498318 --quiet

# === REBUILD ===
terraform plan -var-file prod.tfvars -out tfplan
terraform apply tfplan

# === MOUNT KICK (only with machine images) ===
foreach ($pair in @(@{Vm='protectportal-prod';Zone='asia-southeast1-a';Script='mount-data-disk-prod.sh'},
                    @{Vm='protectportal-dr';  Zone='asia-southeast1-b';Script='mount-data-disk-dr.sh'})) {
    gcloud compute scp "scripts\$($pair.Script)" "$($pair.Vm):/tmp/$($pair.Script)" `
        --tunnel-through-iap --zone=$pair.Zone --project=protectportal-498318
    gcloud compute ssh $pair.Vm --tunnel-through-iap --zone=$pair.Zone --project=protectportal-498318 `
        --command="sudo bash /tmp/$($pair.Script)"
}

# === DNS + CERT ===
$newIp = terraform output -raw load_balancer_ip
Write-Host "Update GoDaddy A record iacat.quanbyit.com -> $newIp" -ForegroundColor Yellow
Read-Host "Press Enter after DNS is updated"

while ($true) {
    $status = gcloud compute ssl-certificates describe protectportal-managed-cert --global `
        --project=protectportal-498318 `
        --format="value(managed.status,managed.domainStatus)"
    Write-Host "$(Get-Date -Format HH:mm:ss) $status"
    if ($status -match "^ACTIVE\s+iacat\.quanbyit\.com=ACTIVE") { break }
    Start-Sleep 60
}

curl.exe -sI "https://iacat.quanbyit.com/" | Select-Object -First 6
```

---

## When the reset *doesn't* go smoothly

| Symptom | Fix |
| --- | --- |
| `oauth2: "invalid_grant"` | Re-run `gcloud auth login` + `gcloud auth application-default login`. |
| Backend complains state file not found | Run the `terraform init -reconfigure` in Step 0.5 — you re-initialised without `-reconfigure` and Terraform got confused. |
| State lock left over from a killed run | `terraform force-unlock <LOCK_ID>` — only after confirming no other apply is running. |
| Cert stuck `FAILED_NOT_VISIBLE` after >30 min | DNS hasn't propagated to Google's resolver yet. `Resolve-DnsName iacat.quanbyit.com -Server 8.8.8.8` — if it doesn't show your new IP, wait. If it does and the cert still fails, force a recreate: `terraform apply -replace="google_compute_managed_ssl_certificate.portal[0]" -var-file prod.tfvars`. |
| Mount step says `device not present after 30s` | The MI didn't carry the data disk and `attached_disk` is still propagating. Wait 30 seconds and re-run the mount kick. |
| `audit_logs` bucket re-creation conflicts with retained old bucket | The new bucket has a random suffix in its name — Terraform creates one with a fresh random_id. Old bucket is unrelated; ignore it (or rename it). |
| Application errors after rebuild | Restore data from the pre-reset snapshot per Step 6. If the application schema changed, run app-team migrations. |

---

## Cost of one reset cycle

- **Time**: 60–90 minutes end to end (including waiting for the SSL cert).
- **Cost**: ~$10 — the pre-reset snapshots are ~2 GB each compressed (delta from last daily), small audit log storage churn. The bigger ongoing cost is the running production VMs.
- **User-visible**: full portal outage from "terraform destroy" until the cert flips `ACTIVE`. Plan for off-hours.

If you reset more than once a month, that's a signal to question the architecture — IaC should converge, not be cycled. Look at `terraform apply -replace=<resource>` for targeted recreates that don't take everything down.
