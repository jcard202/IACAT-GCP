# Shared Custom Machine Image — Build and Use

By default, the ProtectPortal stack boots both VMs from `ubuntu-os-cloud/ubuntu-2204-lts` and runs a startup script that installs nginx, the Ops Agent, fail2ban, etc. on first boot.

For most production deploys you'll want to **bake that baseline into a custom image** and have both prod and DR boot from the same image. Benefits:

- **Identical baselines.** Prod and DR are guaranteed to start with the same kernel, packages, and config — no drift from startup-script flakiness.
- **Faster boot.** A VM created from a custom image with everything pre-installed is ready in ~30 seconds instead of ~3 minutes.
- **Reproducible.** You can roll back to a known-good image at any time.
- **Air-gapped friendly.** A VM built from a custom image doesn't need to reach `apt` repos or `dl.google.com` on first boot.

This guide walks through the build → use → re-bake loop.

---

## When to use this vs. just running with the default

| Situation | Use shared image? |
| --- | --- |
| First-time bring-up / initial deploy | No — boot from `ubuntu-2204-lts`, let the startup script run, then build the image from the result |
| Production deploys after the baseline is stable | **Yes** |
| Test/sandbox iteration on the IaC | No — startup scripts give you fast feedback when you change them |
| Adding a new system package to all VMs | Update startup scripts → re-build the image → re-apply |
| Adding an application package | Use the application's own deploy pipeline, not the OS image |

---

## Workflow at a glance

```
┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────────────┐
│ 1. Deploy with  │    │ 2. Configure prod VM │    │ 3. Run                  │
│    Ubuntu image │ →  │    (startup script   │ →  │    build-shared-image   │
│    (no shared)  │    │    + any extras)     │    │    on prod VM           │
└─────────────────┘    └──────────────────────┘    └─────────────────────────┘
                                                              │
                                                              ▼
                       ┌──────────────────────┐    ┌─────────────────────────┐
                       │ 5. Both VMs rebuild  │    │ 4. Set shared_image in  │
                       │    from the image    │ ←  │    tfvars + apply       │
                       └──────────────────────┘    └─────────────────────────┘
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │ 6. Iterate: update   │
                       │    prod, re-build,   │
                       │    update family,    │
                       │    re-apply DR       │
                       └──────────────────────┘
```

---

## Step 1 — Initial deploy with the default Ubuntu image

If you haven't deployed yet, run the standard flow with `shared_image` left empty (the default):

```powershell
terraform init -reconfigure `
    -backend-config="bucket=iacat-prod-tfstate" `
    -backend-config="prefix=protectportal/prod"

terraform apply -var-file prod.tfvars -auto-approve
```

Both VMs boot from `ubuntu-os-cloud/ubuntu-2204-lts` and run their startup scripts.

## Step 2 — Wait for the prod VM to be fully baked

The startup script logs to `/var/log/protectportal-startup.log`. Wait for the `done` line:

```powershell
gcloud compute ssh protectportal-prod `
    --zone=asia-southeast1-a `
    --tunnel-through-iap `
    --project=iacat-prod `
    --command="sudo tail -30 /var/log/protectportal-startup.log | grep -E 'begin|done'"
```

**PASS:** at minimum one `begin` line at the top and one `done` line at the bottom.

This is also the right point to SSH in and apply any extras the startup script doesn't cover — extra packages, an additional `apt` repo, a security agent, etc. Whatever's on the disk when you snapshot it ends up in the image.

## Step 3 — Build the image

```powershell
# Dry-run first — it prints exactly what would be created and exits
.\scripts\build-shared-image.ps1 -ProjectId iacat-prod

# Once you're happy, build for real
.\scripts\build-shared-image.ps1 -ProjectId iacat-prod -Confirm
```

The script:
1. Stops the prod VM (required — creating an image from a running VM can capture inconsistent disk state).
2. Takes a safety snapshot of the boot disk (`<prefix>-base-<timestamp>-snap`).
3. Creates an image named `protectportal-base-<yyyyMMddHHmm>` in image family `protectportal-base`.
4. Restarts the prod VM.

End-to-end takes ~6–8 minutes. The prod VM is unreachable while it's stopped (~3 of those minutes).

Output finishes with the literal line to paste into your tfvars:

```
shared_image = "iacat-prod/family/protectportal-base"
```

## Step 4 — Tell Terraform to use the image

Edit `prod.tfvars`:

```hcl
shared_image = "iacat-prod/family/protectportal-base"
```

> **Image family vs. exact image name:**
> - `iacat-prod/family/protectportal-base` — always picks the **latest** image in the family. New builds automatically take effect next apply.
> - `iacat-prod/protectportal-base-202606031430` — pins to that **exact build**. Safer for production; explicit re-apply required to upgrade.
>
> Production usually wants the exact-build form. Test can use the family form for fast iteration.

```powershell
terraform plan -var-file prod.tfvars -out tfplan
```

**Expected plan:**
- `google_compute_instance.prod` — `# forces replacement` (boot disk image changed).
- `google_compute_instance.dr` — `# forces replacement` (same).
- `google_compute_disk.prod_data` / `.dr_data` — **no change**. They're separate resources with `prevent_destroy = true`; the VM replacement re-attaches them.

Confirm those three lines, then:

```powershell
terraform apply tfplan
```

Both VMs are destroyed and recreated. Total replacement time: ~5 minutes. The data disks survive intact.

## Step 5 — Verify both VMs are on the new image

```powershell
gcloud compute instances describe protectportal-prod `
    --zone=asia-southeast1-a `
    --project=iacat-prod `
    --format="value(disks[0].licenses[0].basename(),disks[0].source.basename())"

gcloud compute instances describe protectportal-dr `
    --zone=asia-southeast1-b `
    --project=iacat-prod `
    --format="value(disks[0].licenses[0].basename(),disks[0].source.basename())"
```

Drill into the boot disk to confirm the source image:

```powershell
gcloud compute disks describe protectportal-prod `
    --zone=asia-southeast1-a `
    --project=iacat-prod `
    --format="value(sourceImage.basename())"
```

**PASS:** prints the image name you built (`protectportal-base-...`).

## Step 6 — Iterate (when the baseline needs to change)

Anytime you need to update the baseline:

1. SSH into prod, make the change (e.g. `apt install whatever`).
2. Test it.
3. Re-run `.\scripts\build-shared-image.ps1 -ProjectId iacat-prod -Confirm`. A new timestamped image is added to the same family.
4. If `shared_image` pins the family, `terraform apply` replaces both VMs with the new image.
5. If `shared_image` pins an exact name, update `prod.tfvars` to the new name and `terraform apply`.

The previous image stays in the project — handy for rollback. Clean up periodically:

```powershell
gcloud compute images list --project=iacat-prod `
    --filter="family:protectportal-base" `
    --sort-by=~creationTimestamp `
    --format="table(name,creationTimestamp,diskSizeGb,status)"

# Delete one you don't need anymore (after confirming nothing depends on it)
gcloud compute images delete protectportal-base-<old-timestamp> --project=iacat-prod --quiet
```

---

## What's in the image

Whatever was on prod's boot disk at snapshot time. The default startup script installs:

- `nginx` with the security-headers config
- `google-cloud-ops-agent` (logs + metrics)
- `certbot` + `python3-certbot-nginx` (fallback cert renewal)
- `fail2ban`
- `unattended-upgrades` configured for security patches
- ufw configured for 22/80/443
- SSH hardening (`PasswordAuthentication no`, `PermitRootLogin no`)

Both VMs install PostgreSQL 16 from the same PGDG repo. The prod VM relocates its cluster to `/data/postgres/16/main`; the DR VM relocates to `/backups/postgres/16/main`. When the shared image is built from prod, it already carries the PG 16 packages + the prod-side data dir layout. On first DR boot the DR startup script re-runs (`apt-get install` is a no-op for already-installed PG), drops the cluster at the prod path if present, and re-creates it at the DR path.

If you want everything DR-specific baked into the image instead, build it from the DR VM:

```powershell
.\scripts\build-shared-image.ps1 -ProjectId iacat-prod -SourceVm protectportal-dr -SourceZone asia-southeast1-b -Confirm
```

But the typical pattern is to build from prod (which has the production-side config) and let the DR startup script reconcile the per-VM paths.

---

## Data disks are NOT in the image

The custom image captures only the **boot disk** (the OS + installed packages + per-VM config). The data disks (`protectportal-prod-data` at `/data`, `protectportal-dr-data` at `/backups`) are separate `google_compute_disk` resources with `prevent_destroy = true`. They survive VM recreation and stay attached.

Your application data, daily SQL dumps, etc. are safe across image rebuilds.

---

## Disk image vs. Machine image

GCP has two artifact types for "snapshot of a VM" and the Terraform supports both, per VM, per environment:

| | **Disk image** | **Machine image** |
| --- | --- | --- |
| GCP page | Compute Engine → **Images** | Compute Engine → **Machine images** |
| Captures | One disk (typically the boot disk) | Entire VM: every attached disk + metadata + most VM settings |
| Terraform attribute | `boot_disk.initialize_params.image` | `source_machine_image` (on `google_compute_instance_from_machine_image`) |
| Our variable | `prod_disk_image` / `dr_disk_image` (or `shared_image` for both) | `prod_machine_image` / `dr_machine_image` |
| Data disk handling | Independent `google_compute_disk` is attached separately. Survives VM replacement (`prevent_destroy = true`). | The MI's restored data disk becomes the live disk. Our separate `google_compute_disk` resources still exist but are **not attached** to the MI-restored VM. |
| Right for | Most cases. Clean separation between OS and data lifecycles. | "Lift and shift" of a fully-configured VM you don't want to deconstruct. |

You pick **per VM** via tfvars — prod can use one type while DR uses the other. Setting both for the same VM is an error (mutual exclusion enforced by the resource gating).

### Disk image — typical case

```hcl
prod_disk_image = "iacat-prod/family/protectportal-base"
dr_disk_image   = "iacat-prod/family/protectportal-base"
```

Both VMs boot from the latest image in `protectportal-base`. The 2 TB / 500 GB data disks are still managed as `google_compute_disk.prod_data` / `.dr_data` and reattach on every VM replacement.

Shortcut for "both VMs from the same disk image":

```hcl
shared_image = "iacat-prod/family/protectportal-base"
```

(Equivalent to setting `prod_disk_image` and `dr_disk_image` to the same value. The per-VM variables, when set, override `shared_image`.)

### Letting the machine image take precedence

By default, when `prod_machine_image` / `dr_machine_image` is set, our Terraform still overrides `machine_type`, `scheduling`, and `shielded_instance_config` on the restored VM — useful when the MI source was misconfigured and you want our defaults to fix it. To **let the MI's captured values win** instead:

```hcl
prod_machine_image              = "projects/.../machineImages/prod-mi"
prod_inherit_from_machine_image = true

dr_machine_image                = "projects/.../machineImages/dr-mi"
dr_inherit_from_machine_image   = true
```

| Field | Inherited from MI when `inherit = true` | Notes |
| --- | --- | --- |
| `machine_type` | ✓ | E.g. if the MI source was `n2-standard-4`, the restored VM is `n2-standard-4` regardless of `var.prod_machine_type`. |
| `scheduling` (automatic_restart, on_host_maintenance, preemptible, provisioning_model) | ✓ | Whatever the MI captured. |
| `shielded_instance_config` (Secure Boot, vTPM, integrity monitoring) | ✓ | Inherited as captured. Note: spec verification (C.8) will fail if the MI source had these disabled. |
| `network_interface` (subnet, public IP) | ✗ — always overridden | The MI's network points at the source project's VPC, which doesn't exist here. Forced to `ppt-test-vpc` / `protectportal-vpc`. |
| `service_account` | ✗ — always overridden | The MI's SA email refers to the source project's SA, not ours. Forced to `*-prod-vm@` / `*-dr-vm@`. |
| `tags` | ✗ — always overridden | Firewall rules in *this* project key off `ssh-iap`, `http-backend`, `protectportal-prod/dr`. |
| `metadata` (`enable-oslogin`, `db-allow-cidr`, etc.) | ✗ — always overridden | OS Login enforcement, postgres CIDR-from-var, etc. need to match this deploy. |
| `labels` | ✗ — always overridden | Cost / observability labels. |
| `metadata_startup_script` | ✗ — always overridden | The mount script needs to know which data disk to look for. |
| `deletion_protection` | ✗ — always set | Driven by `var.enable_deletion_protection`. |

So: the **infrastructure** (network, IAM, firewall) always tracks our Terraform; the **VM shape** (size, scheduling, security profile) can be made to track the MI.

### Machine image — when you want a whole-VM snapshot

```hcl
prod_machine_image = "projects/iacat-prod/global/machineImages/protectportal-prod-mi"
dr_machine_image   = "projects/iacat-prod/global/machineImages/protectportal-dr-mi"
```

When set, Terraform uses `google_compute_instance_from_machine_image` instead of the regular `google_compute_instance`. The boot disk and the source VM's data disk (if any) are restored from the MI.

### Choosing where the data disk comes from

If the machine image was captured from a VM that had a data disk, you have two options when restoring:

**Option 1 — Use the MI's data disk** (set `*_create_data_disk = false`)

The data disk inside the MI becomes the live data disk on the new VM. Skip our separately-managed `google_compute_disk` entirely.

```hcl
prod_create_data_disk = false   # don't create our own
dr_create_data_disk   = false
```

What's skipped: the `google_compute_disk` resource, the `google_compute_attached_disk` binding, the daily snapshot policy attachment, and the `mount-data-disk-*.sh` script in `metadata_startup_script`. The MI is responsible for mounting whatever data disk it carries (typically via fstab UUID entries baked into the image).

When to use it: the MI is a complete VM snapshot you trust to be self-sufficient — you don't need our prevent_destroy lifecycle on the data, and the data already inside the MI is the data you want.

**Option 2 — Use OUR managed data disk** (default `*_create_data_disk = true`)

We create `google_compute_disk.{prod,dr}_data`, attach via `google_compute_attached_disk`, and the mount script runs on every boot.

When to use it:
- You captured the MI from a VM with the data disk detached, OR
- You want the `prevent_destroy` lifecycle on the data, OR
- You want our daily snapshot schedule against the data, OR
- You want to swap images while keeping the existing data

**WARNING — don't mix both.** If the MI carries a data disk AND `*_create_data_disk = true`, you'll end up with two disks attached and likely a `device_name` collision (both want `protectportal-{prod,dr}-data`). Either build the MI from a VM with the data disk detached, or set `*_create_data_disk = false`.

**When to use which:**

| Scenario | Recommendation |
| --- | --- |
| First-time bring-up | Default Ubuntu image |
| Steady production with stable baseline | **Disk image** built via `scripts/build-shared-image.ps1` |
| Image shared by another team / vendor (boot disk only) | **Disk image**, full long-form path |
| Image shared by another team / vendor (whole VM) | **Machine image** — but verify the source VM didn't have data they don't intend to ship |
| Promoting test → prod with the same artifact | **Disk image** — production data lives in the separately-managed data disk, untouched by image swaps |
| Lifting an entire fully-configured legacy VM | **Machine image** |

## Using an image shared by another GCP account / project

When the image is owned by someone else's Google Cloud project (a separate org, a vendor, a sibling team), the only changes are **IAM on the source side** and the **`shared_image` value format**. The Terraform doesn't change.

### Step 1 — Information to request from the image owner

Send them this checklist. Without all five answers, you can't use the image.

| You need | Example | Why |
| --- | --- | --- |
| Source GCP project ID | `iacat-shared-images` | Used in the image reference path |
| Image name or family name | `protectportal-golden-v3` *or* `family/protectportal-golden` | What you'll set `shared_image` to |
| Confirmed grant: `roles/compute.imageUser` on the image (or project) to your principals | (see Step 2 below) | Required to read the image during VM creation |
| Storage location of the image | `asia-southeast1`, `asia`, or `multi-region` | The image must be reachable from your VM's region. `asia-southeast1` or any `asia` multi-region works for our Singapore deploy |
| License / OS info | `Ubuntu 22.04`, no extra paid licenses | Some images carry licenses (RHEL, Windows Server) that your project gets billed for |

If the image is **CMEK-encrypted** (the owner used a customer-managed encryption key), also request:

| You need | Example |
| --- | --- |
| KMS key resource name | `projects/iacat-shared-keys/locations/asia-southeast1/keyRings/images/cryptoKeys/golden` |
| Confirmed grant: `roles/cloudkms.cryptoKeyDecrypter` on that key to your principals | (see Step 2) |

### Step 2 — Principals the owner must grant access to

The owner needs to grant `roles/compute.imageUser` to **two** principals on your side. Send them both:

```
1. Your operator account (whoever runs terraform apply):
     user:devops@quanbyit.com

2. Your project's Compute Engine service agent (so the VM creation API
   call can read the image):
     serviceAccount:service-<PROJECT_NUMBER>@compute-system.iam.gserviceaccount.com
```

Get your project number:

```powershell
gcloud projects describe iacat-prod --format="value(projectNumber)"
```

So if `iacat-prod` is project number `90152921019`, the service agent email is `service-90152921019@compute-system.iam.gserviceaccount.com`.

The owner runs (one of the following) on **their** project:

**A. Grant on the specific image only (most restrictive — recommended for vendors):**

```bash
# Run by the image OWNER on the SOURCE project
gcloud compute images add-iam-policy-binding protectportal-golden-v3 \
    --project=iacat-shared-images \
    --member=user:devops@quanbyit.com \
    --role=roles/compute.imageUser

gcloud compute images add-iam-policy-binding protectportal-golden-v3 \
    --project=iacat-shared-images \
    --member=serviceAccount:service-90152921019@compute-system.iam.gserviceaccount.com \
    --role=roles/compute.imageUser
```

**B. Grant on the whole project (lets the family pointer auto-pick latest):**

```bash
# Run by the image OWNER on the SOURCE project
gcloud projects add-iam-policy-binding iacat-shared-images \
    --member=user:devops@quanbyit.com \
    --role=roles/compute.imageUser

gcloud projects add-iam-policy-binding iacat-shared-images \
    --member=serviceAccount:service-90152921019@compute-system.iam.gserviceaccount.com \
    --role=roles/compute.imageUser
```

Use **B** if `shared_image` references an image *family* — the family pointer needs project-level read so the latest image in the family can resolve.

### Step 3 — Verify you can actually read the image

Before changing anything in Terraform, prove the grant works from your side:

```powershell
# As the operator account (the one that runs terraform apply)
gcloud auth login   # if not already
gcloud compute images describe protectportal-golden-v3 `
    --project=iacat-shared-images `
    --format="table(name,family,diskSizeGb,sourceDisk.basename(),licenses[].basename().list(),status)"
```

**PASS:** the table prints. `status` should be `READY`.

**FAIL modes and fixes:**

| Error | What it means | Fix |
| --- | --- | --- |
| `(gcloud.compute.images.describe) HTTPError 403` | You don't have `compute.imageUser` on the image | Owner re-runs Step 2 with the correct principal |
| `(gcloud.compute.images.describe) NOT_FOUND` | Wrong image name or wrong source project | Confirm the values from Step 1 with the owner |
| `(gcloud.compute.images.describe) HTTPError 404 ... global/images` | The image isn't actually in the project you were told | Owner needs to share the right project |

If you intend to reference the image as a family, also verify the family resolves:

```powershell
gcloud compute images describe-from-family protectportal-golden `
    --project=iacat-shared-images `
    --format="value(name,family,status)"
```

**PASS:** prints the latest image name in that family. If this errors but `describe` for a specific image works, the owner needs to upgrade your grant from image-level to project-level (option **B** above).

### Skipping the startup script entirely

If the shared image already includes everything our startup script does — packages installed, ufw configured, SSH hardened, PostgreSQL cluster created at the right path, pg_hba populated, etc. — you can disable the provisioning script so Terraform doesn't even hand it to the VM:

```hcl
shared_image       = "iacat-shared-images/protectportal-golden-v3"
run_startup_script = false
```

**What still runs when `run_startup_script = false`:**

The data-disk mount script (`scripts/mount-data-disk-{prod,dr}.sh`) is **always** included in the VM's `metadata_startup_script` — it formats (if blank), mounts, and `fstab`-pins the data disk on every boot regardless of this flag. It has no dependency on packages from the bigger provisioning script and is fully idempotent. The mount runs even on VMs built from a fully-baked image, so `/data` and `/backups` are always ready by the time the image's own init starts looking for them.

**What is skipped when `run_startup_script = false`:**

- All `apt-get install` calls (PostgreSQL, nginx, fail2ban, etc.) — your image owns them
- ufw rule programming — your image owns the host firewall
- SSH hardening config — your image owns `/etc/ssh/sshd_config.d/`
- nginx security-headers config — your image owns nginx config
- PostgreSQL cluster relocation + `pg_hba.conf` injection — your image must place the cluster at `/data/postgres/16/main` (prod) or `/backups/postgres/16/main` (DR) itself, and configure `pg_hba.conf` as it sees fit

Per-VM metadata (`db-allow-cidr`, `enable-oslogin`, etc.) is still set on the VM, so an image-side script can read those values if needed. The prod VM's `db-allow-cidr` metadata key still carries `var.vpc_cidr_dr` — useful if your image's own init wants to use it to populate `pg_hba.conf`.

### Step 4 — Set `shared_image` in your tfvars

Use the full cross-project form. Both shorthand and long form work:

```hcl
# Long form (most explicit, recommended for production):
shared_image = "projects/iacat-shared-images/global/images/protectportal-golden-v3"

# Shorthand for a specific image:
shared_image = "iacat-shared-images/protectportal-golden-v3"

# Shorthand for a family pointer (requires project-level grant from Step 2):
shared_image = "iacat-shared-images/family/protectportal-golden"
```

Production (`prod.tfvars`) — pin to a specific image name so unexpected updates by the image owner can't surprise you mid-incident:

```hcl
shared_image = "iacat-shared-images/protectportal-golden-v3"
```

Test (`test.tfvars`) — pinning to the family is fine, you want to see the latest image automatically:

```hcl
shared_image = "iacat-shared-images/family/protectportal-golden"
```

### Step 4.5 — (Recommended) Prove data disks survive the VM replacement

Before you point production at a brand-new image, validate that the destroy/replace path keeps the data disks intact. Run this in the **test** environment first.

```powershell
# 1. Drop a marker file on each of the four disks
.\scripts\test-disk-persistence.ps1 -ProjectId iacat-test -Action Create

# 2. Force both VMs to be replaced (this is what changing shared_image does)
terraform apply -var-file test.tfvars `
    -replace=google_compute_instance.prod `
    -replace=google_compute_instance.dr -auto-approve

# 3. After both VMs come back up, verify
.\scripts\test-disk-persistence.ps1 -ProjectId iacat-test -Action Verify
```

The verify step expects:

| Marker | Expected state | Why |
| --- | --- | --- |
| `/root/boot-marker-prod.txt` | GONE | Boot disk has `auto_delete = true`; destroyed with the VM |
| `/data/data-marker.txt` | PRESENT | Data disk is a separate `google_compute_disk` with `prevent_destroy = true` |
| `/root/boot-marker-dr.txt` | GONE | Same as prod boot |
| `/backups/backup-marker.txt` | PRESENT | Same as prod data |

The script prints a `PASS` / `FAIL` table. **Do not proceed to production** if data markers go missing — that would mean the data disks are at risk during a real `shared_image` swap.

### Step 5 — Plan and apply

```powershell
terraform plan -var-file prod.tfvars -out tfplan
```

**Expected:**
- `google_compute_instance.prod` — replacement forced (boot disk image changed)
- `google_compute_instance.dr` — replacement forced
- Data disks unchanged (separate resources with `prevent_destroy`)

If the plan succeeds, the IAM is sufficient. Apply:

```powershell
terraform apply tfplan
```

If apply fails with `Required 'compute.images.useReadOnly' permission` (or similar), it's almost always that you granted to one principal but not the other — usually missing the compute-system service agent in Step 2. Grant it and re-apply.

### Step 6 — Verify the VMs actually booted from the shared image

```powershell
gcloud compute disks describe protectportal-prod `
    --zone=asia-southeast1-a --project=iacat-prod `
    --format="value(sourceImage)"

gcloud compute disks describe protectportal-dr `
    --zone=asia-southeast1-b --project=iacat-prod `
    --format="value(sourceImage)"
```

**PASS:** both print a URL ending in `projects/iacat-shared-images/global/images/protectportal-golden-v3`.

---

### Caveats with cross-project shared images

| Caveat | What to know |
| --- | --- |
| **License billing** | Some images carry per-vCPU licensing (RHEL, Windows Server, SQL Server). Your project gets billed for the licenses on the VM hours, not the image owner's. Confirm in advance. |
| **Image deletion** | If the owner deletes the source image, your next `terraform apply` (when it tries to replace a VM) will fail with `NOT_FOUND`. Pin to image *names* in production and ask the owner to give 30+ days notice before deleting a published version. |
| **Family changes** | If you pin to a family pointer, an image rebuild on the owner's side immediately becomes effective on your next `terraform apply`. Treat the owner's image promotion as a deploy-able change in your own pipeline. |
| **Region availability** | If the image is regionally-stored in `us-central1` and your VMs are in `asia-southeast1`, the API copies the image cross-region at VM-create time (slow first apply, no recurring cost). Multi-region or `asia-southeast1`-resident is faster. |
| **No "list" without grant** | `gcloud compute images list --project=<other-project>` only shows images you have access to. If the owner shared exactly one, the list is short — that's fine. |
| **Image owner can't see your usage** | The owner only sees who they granted `imageUser` to, not whether you've actually deployed VMs from it. Communicate out-of-band. |

---

## Common questions

### Can I use a Packer-built image instead?

Yes — `shared_image` accepts any valid GCE image reference:

```hcl
shared_image = "iacat-prod/protectportal-packer-20260603"          # exact name
shared_image = "iacat-prod/family/protectportal-base"              # family pointer
shared_image = "projects/iacat-shared/global/images/family/golden" # cross-project
```

If your org has a centralised image-bake pipeline, point `shared_image` at the output of that pipeline and skip this script entirely.

### What about hardening baselines (CIS, STIG)?

Use the shared image as the artifact of your hardening pipeline:
1. Boot a fresh VM from `ubuntu-2204-lts`.
2. Run your CIS/STIG-hardening tooling (Ansible, Chef, ...).
3. Snapshot via `build-shared-image.ps1`.
4. The resulting image carries the hardened baseline forward; every VM rebuild starts from compliance-ready state.

### Can prod and DR use different images?

Yes, but it defeats the "identical baseline" benefit. To do it, replace `local.effective_image` in `compute.tf` with two separate locals (`prod_image` and `dr_image`) gated on different variables. Out of scope here.

### How do I roll back to a previous image?

Update `shared_image` in tfvars to the previous timestamped name and `terraform apply`. Both VMs roll back. Or, if `shared_image` pins the family, update the family to point at the old image:

```powershell
# 1. Find the previous image
gcloud compute images list --project=iacat-prod --filter="family:protectportal-base" --sort-by=~creationTimestamp

# 2. Repoint the family to it
gcloud compute images update protectportal-base-<old> --project=iacat-prod --family=protectportal-base
```

The family always resolves to the **most recently created** image with that family label, so this effectively means: create a new image *from the old one's source* to bump the timestamp. Easier path: pin to exact image names in production.

---

## Troubleshooting

### "Image already exists"

The script names images with minute-resolution timestamps. Re-run after the next minute, or delete the existing image:

```powershell
gcloud compute images delete <image-name> --project=iacat-prod --quiet
```

### Build script fails with "Source VM not found"

Check the VM name and zone:

```powershell
gcloud compute instances list --project=iacat-prod --filter="name~'protectportal'"
```

Pass `-SourceVm` and `-SourceZone` explicitly if they differ from the defaults.

### `terraform plan` after setting `shared_image` shows nothing changing

Confirm the file was saved and the value reaches Terraform:

```powershell
terraform console -var-file prod.tfvars
> var.shared_image
"iacat-prod/family/protectportal-base"
> local.effective_image
"iacat-prod/family/protectportal-base"
```

If `local.effective_image` is still the Ubuntu default, something's wrong with `prod.tfvars` formatting.

### Both VMs rebuilt but `/data` is empty

Should not happen — the data disks are separate resources and stay attached. If it did, you almost certainly have `prevent_destroy = true` removed somewhere it shouldn't be. Restore from the daily snapshot (see `docs/OPERATIONS.md#restore-from-a-snapshot`).

### `effective_image` value gives `googleapi: Error 400: Invalid value for field 'resource.disks[0].initializeParams.sourceImage'`

The image reference format is wrong. Valid forms:

```
projects/PROJECT/global/images/IMAGE
projects/PROJECT/global/images/family/FAMILY
PROJECT/IMAGE                # shorthand
PROJECT/family/FAMILY        # shorthand
family/FAMILY                # short-shorthand, same project as the VM
```

Stick to one of those. The build script prints the correct form for you to paste.
