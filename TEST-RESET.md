# Test Environment Reset Procedure

End-to-end teardown of the `iacat-test` deploy followed by a fresh rebuild. Use whenever you want a known-clean test state — between major changes, before a UAT walkthrough, or after a failed apply has left the state confused.

Procedure handles all three deployment paths the stack supports:

- Default Ubuntu image
- `shared_image` / per-VM `prod_disk_image` + `dr_disk_image` (disk-image path)
- `prod_machine_image` + `dr_machine_image` (machine-image path)

The state-rm step lists resources for **all** paths — the ones that don't exist for your current deploy will simply be reported as "not in state" and ignored. Harmless.

> Run all of this from `C:\Users\Administrator\IACATProctectPortal` with the test backend already initialised (`terraform init -reconfigure -backend-config="bucket=iacat-test-tfstate" -backend-config="prefix=protectportal/test"`). Re-authenticate with `gcloud auth login` and `gcloud auth application-default login` if either has expired.

---

## Why this procedure has multiple destroy passes

Three things block a single-shot `terraform destroy`:

| Blocker | Why | How this procedure handles it |
| --- | --- | --- |
| `lifecycle { prevent_destroy = true }` on data disks | Production safety guard — meta-argument must be a literal. | State-rm the disks (and any `google_compute_attached_disk` that references them) before the second destroy pass. Disks are deleted manually via gcloud at the end. |
| Audit-log GCS bucket has objects, no `force_destroy = true` | Terraform refuses to delete a non-empty bucket without explicit consent. | Empty/delete the bucket manually in the Console after the second pass, then run destroy a third time. |
| `google_compute_attached_disk` references the data disks | After state-rm of the disks, the binding's reference can't resolve. | Drop the bindings from state in the same step as the disks. |

---

## Teardown

### Step 1 — First destroy attempt (fails on `prevent_destroy`)

```powershell
terraform destroy -var-file test.tfvars -auto-approve
```

Expected to fail at plan time on:
```
Resource google_compute_disk.prod_data has lifecycle.prevent_destroy set ...
Resource google_compute_disk.dr_data has lifecycle.prevent_destroy set ...
```

### Step 2 — State-rm the disks + their attached-disk bindings

```powershell
terraform state rm `
    google_compute_disk.prod_data `
    google_compute_disk.dr_data `
    'google_compute_attached_disk.prod_data[0]' `
    'google_compute_attached_disk.dr_data[0]'
```

The last two entries only exist if your deploy used machine images (`prod_machine_image` / `dr_machine_image` set). Running the command anyway prints `Not in state` and continues — no error. Quoting `[0]` with single quotes is required so PowerShell doesn't try to interpret the brackets.

### Step 3 — Second destroy (gets through VMs, network, monitoring)

```powershell
terraform destroy -var-file test.tfvars -auto-approve
```

This pass tears down ~48 resources (everything except the audit bucket and the `random_id.audit_suffix`). It fails at the very end on:

```
Error: Error trying to delete bucket iacat-test-ppt-test-audit-XXXX containing
objects without `force_destroy` set to true
```

### Step 4 — Empty + delete the audit bucket manually

The bucket contains audit log entries written during the deployment's lifetime. Terraform's `google_storage_bucket` resource defaults to refusing the delete; manually clear it via the Console:

```powershell
Start-Process "https://console.cloud.google.com/storage/browser?project=iacat-test"
```

In the Console:
1. Find the bucket starting with `iacat-test-ppt-test-audit-`.
2. Tick the row → **DELETE** → confirm.
3. Acknowledge any retention-policy warning (1-day WORM lock may delay the delete a few seconds).

> CLI alternative if you'd rather: `gcloud storage rm --recursive "gs://iacat-test-ppt-test-audit-XXXXXXXX" --quiet`

```powershell
Read-Host "Press Enter once the audit bucket is fully deleted"
```

### Step 5 — Third destroy (sweeps the last two resources)

```powershell
terraform destroy -var-file test.tfvars -auto-approve
```

Cleans `google_storage_bucket.audit_logs` (Terraform sees the 404, removes it from state) and `random_id.audit_suffix`.

### Step 6 — Delete the orphaned data disks

The data disks were state-rm'd in Step 2 but still exist in GCP. They are no longer attached to anything (the VMs are gone), so deletion succeeds immediately:

```powershell
gcloud compute disks delete ppt-test-prod-data --zone=asia-southeast1-a --project=iacat-test --quiet
gcloud compute disks delete ppt-test-dr-data   --zone=asia-southeast1-b --project=iacat-test --quiet
```

---

## Verify clean

```powershell
Write-Host "Instances:        $((gcloud compute instances list --project=iacat-test --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Disks:            $((gcloud compute disks list --project=iacat-test --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Networks (custom):$((gcloud compute networks list --project=iacat-test --filter='name!=default' --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Reserved IPs:     $((gcloud compute addresses list --project=iacat-test --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Forwarding rules: $((gcloud compute forwarding-rules list --project=iacat-test --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Custom SAs:       $((gcloud iam service-accounts list --project=iacat-test --filter='email~ppt-test' --format='value(email)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Storage buckets:  $((gcloud storage buckets list --project=iacat-test --format='value(name)' 2>$null | Measure-Object -Line).Lines) (tfstate bucket is intentional)"
Write-Host "Machine images:   $((gcloud beta compute machine-images list --project=iacat-test --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Disk images:      $((gcloud compute images list --project=iacat-test --no-standard-images --format='value(name)' 2>$null | Measure-Object -Line).Lines)"
Write-Host "Terraform state:  $((terraform state list 2>&1 | Measure-Object -Line).Lines) resources"
```

Expected:

| Counter | Value | Note |
| --- | --- | --- |
| Instances | 0 | |
| Disks | 0 | |
| Networks (custom) | 0 | `default` VPC is GCP's built-in, untouched |
| Reserved IPs | 0 | LB IP gone |
| Forwarding rules | 0 | |
| Custom SAs | 0 | `ppt-test-prod-vm`, `ppt-test-dr-vm` released |
| Storage buckets | 1 | `iacat-test-tfstate` — needed for the rebuild |
| Machine images | 2 or 0 | `prod-img`, `dr-img` if you built them; intentional |
| Disk images | 0 or N | Any from `build-shared-image.ps1` runs |
| Terraform state | 0 resources | |

---

## Rebuild

```powershell
terraform plan -var-file test.tfvars -out tfplan
terraform apply tfplan
```

Plan should show **~40 resources to add, 0 to change, 0 to destroy**. Apply takes 5–7 minutes.

Which image path runs depends on what's currently uncommented in `test.tfvars`:

| `test.tfvars` setting | Path taken |
| --- | --- |
| `shared_image = "..."` | Both VMs from that disk image |
| `prod_disk_image` and/or `dr_disk_image` set | Per-VM disk image |
| `prod_machine_image` and/or `dr_machine_image` set | Per-VM machine image (`google_compute_instance_from_machine_image`) |
| Nothing of the above uncommented | Default Ubuntu LTS |

---

## Mount kick (required when using machine images)

`google_compute_attached_disk` is a separate Terraform resource — the data disk attaches to the VM **after** the VM has booted from the MI. The startup script's 30-second wait loop usually catches the attach, but sometimes the VM boots faster and the script gives up before the disk shows up. Re-running the mount script in place is idempotent and guarantees the mount:

```powershell
foreach ($pair in @(@{Vm='ppt-test-prod';Zone='asia-southeast1-a';Script='mount-data-disk-prod.sh'},
                    @{Vm='ppt-test-dr';  Zone='asia-southeast1-b';Script='mount-data-disk-dr.sh'})) {
    Write-Host "=== $($pair.Vm) ===" -ForegroundColor Cyan
    gcloud compute scp "scripts\$($pair.Script)" "$($pair.Vm):/tmp/$($pair.Script)" `
        --tunnel-through-iap --zone=$pair.Zone --project=iacat-test
    gcloud compute ssh $pair.Vm --tunnel-through-iap --zone=$pair.Zone --project=iacat-test `
        --command="sudo bash /tmp/$($pair.Script)"
}
```

Skip this step if you're rebuilding **without** machine images — the disk-image path attaches the data disk in the same API call as the VM creation, so the startup script never races.

---

## Verify the rebuild

```powershell
foreach ($pair in @(@{Vm='ppt-test-prod';Zone='asia-southeast1-a';Mount='/data'},
                    @{Vm='ppt-test-dr';  Zone='asia-southeast1-b';Mount='/backups'})) {
    Write-Host "=== $($pair.Vm) ===" -ForegroundColor Cyan
    gcloud compute ssh $pair.Vm --tunnel-through-iap --zone=$pair.Zone --project=iacat-test `
        --command="df -hT $($pair.Mount); grep $($pair.Mount) /etc/fstab"
}
```

Each VM should print its data disk mounted ext4 at the expected mountpoint plus a UUID-based fstab entry that survives reboot.

For a more thorough sanity check, run the spec verification:

```powershell
# See docs/SPEC-VERIFICATION.md for the full checklist
$env:PROJECT  = "iacat-test"
$env:PROD_VM  = "ppt-test-prod"
$env:DR_VM    = "ppt-test-dr"
$env:PROD_ZONE = "asia-southeast1-a"
$env:DR_ZONE  = "asia-southeast1-b"
$env:NAME_PREFIX = "ppt-test"
$env:DOMAIN   = "iacat-test.quanbyit.com"
```

Then walk the sections in `docs/SPEC-VERIFICATION.md`.

---

## TL;DR one-block copy-paste

```powershell
# === TEARDOWN ===
terraform destroy -var-file test.tfvars -auto-approve
terraform state rm `
    google_compute_disk.prod_data `
    google_compute_disk.dr_data `
    'google_compute_attached_disk.prod_data[0]' `
    'google_compute_attached_disk.dr_data[0]'
terraform destroy -var-file test.tfvars -auto-approve
Start-Process "https://console.cloud.google.com/storage/browser?project=iacat-test"
Read-Host "Delete the audit bucket in Console, then press Enter"
terraform destroy -var-file test.tfvars -auto-approve
gcloud compute disks delete ppt-test-prod-data --zone=asia-southeast1-a --project=iacat-test --quiet
gcloud compute disks delete ppt-test-dr-data   --zone=asia-southeast1-b --project=iacat-test --quiet

# === REBUILD ===
terraform plan -var-file test.tfvars -out tfplan
terraform apply tfplan

# === MOUNT KICK (only when using machine images) ===
foreach ($pair in @(@{Vm='ppt-test-prod';Zone='asia-southeast1-a';Script='mount-data-disk-prod.sh'},
                    @{Vm='ppt-test-dr';  Zone='asia-southeast1-b';Script='mount-data-disk-dr.sh'})) {
    gcloud compute scp "scripts\$($pair.Script)" "$($pair.Vm):/tmp/$($pair.Script)" `
        --tunnel-through-iap --zone=$pair.Zone --project=iacat-test
    gcloud compute ssh $pair.Vm --tunnel-through-iap --zone=$pair.Zone --project=iacat-test `
        --command="sudo bash /tmp/$($pair.Script)"
}
```

---

## Total cost of one reset cycle

Reset → empty project → rebuild typically:

- **Time**: ~15 minutes end to end (5 min teardown, 5–7 min rebuild, 2 min mount + verify).
- **Cost**: ~5 cents while the new deploy is running, plus the GCS state versions left behind in `iacat-test-tfstate` (megabytes of state objects).

If you reset more than once a day, consider adding `force_destroy = true` to the audit bucket resource in `monitoring.tf` to skip Step 4. Don't apply that to production.

---

## When the reset *doesn't* go smoothly

| Symptom | Fix |
| --- | --- |
| `oauth2: "invalid_grant"` during destroy | Auth expired. Re-run `gcloud auth login` + `gcloud auth application-default login`. |
| `Some requests did not succeed` from gcloud during verify | Re-auth (same as above), then re-run. |
| State lock left over from a killed run | `terraform force-unlock <LOCK_ID>` — only after confirming no other operator is running an apply. |
| Audit bucket deletion fails with "retention policy" | The 1-day WORM lock prevents deleting objects less than 24h old. Wait it out, or extend the retention setting in `monitoring.tf` to 0 temporarily, re-apply, then delete. |
| Mount step says `device not present after 30s` | The MI didn't carry the data disk and the `attached_disk` is still propagating. Wait ~30 seconds and re-run the mount kick. |
| `terraform plan` shows resources to destroy that you didn't expect | `test.tfvars` has changed since the last apply — eyeball the diff before applying. |
