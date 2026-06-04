# Prerequisites

Everything you need to install, create, and configure **before** running the bootstrap script or `terraform apply`. Follow these steps in order — each section assumes the previous one is done.

Allow ~45 minutes for a fresh setup. Most of the time is waiting for installers and API enablement.

---

## Checklist

By the end of this document you will have:

**Tooling**
- [ ] Terraform `>= 1.6` installed and on PATH
- [ ] Google Cloud SDK (`gcloud`) installed and on PATH
- [ ] Git installed (optional but recommended)

**Cloud account**
- [ ] A Google account with access to the target GCP project
- [ ] A GCP project with **billing enabled**
- [ ] The `Owner` (or equivalent) role on that project
- [ ] `gcloud auth login` complete
- [ ] `gcloud auth application-default login` complete (Terraform reads this)

**Domain + alerting**
- [ ] A registered domain you control, ready to point at the load balancer
- [ ] An email address that will receive monitoring alerts

**Image choice** (pick ONE per VM)
- [ ] Decided whether prod and DR each use default Ubuntu, a custom disk image, or a custom machine image
- [ ] If using a custom image, decided whether it carries the data disk (`*_create_data_disk = false`) or not (default `true`)
- [ ] If using an image shared by another project, confirmed the `roles/compute.imageUser` grant from the owner

---

## 1. Install local tooling (Windows)

> Run **PowerShell as Administrator** for the install commands below. The actual Terraform / gcloud commands later do not need admin rights.

### 1.1 Google Cloud SDK (`gcloud`)

**Option A — winget (fastest, recommended on Windows 10/11):**

```powershell
winget install --id Google.CloudSDK -e
```

**Option B — Chocolatey:**

```powershell
choco install gcloudsdk -y
```

**Option C — Manual installer:**

Download from <https://cloud.google.com/sdk/docs/install#windows> and run `GoogleCloudSDKInstaller.exe`. During install, leave "Run gcloud init" checked.

**Verify:**

```powershell
# Close and reopen PowerShell first so PATH refreshes
gcloud --version
```

Expect output like `Google Cloud SDK 490.x` or newer.

### 1.2 Terraform

**Option A — winget:**

```powershell
winget install --id HashiCorp.Terraform -e
```

**Option B — Chocolatey:**

```powershell
choco install terraform -y
```

**Option C — Manual:**

1. Download the Windows AMD64 zip from <https://developer.hashicorp.com/terraform/downloads>.
2. Extract `terraform.exe` to a folder on your PATH (e.g. `C:\Tools\Terraform\`).
3. Add that folder to PATH via **System Properties → Environment Variables → Path**.

**Verify:**

```powershell
terraform version
```

You need **`>= 1.6.0`**. If you have an older version, upgrade — older Terraforms will fail on the provider version constraint in `versions.tf`.

### 1.3 Git (optional but recommended)

```powershell
winget install --id Git.Git -e
```

Or download from <https://git-scm.com/download/win>.

### 1.4 (Optional) Visual Studio Code + HashiCorp Terraform extension

For syntax highlighting and `terraform fmt` on save:

```powershell
winget install --id Microsoft.VisualStudioCode -e
code --install-extension HashiCorp.terraform
```

---

## 2. Google Cloud setup

### 2.1 Create or pick a GCP project

You need a project with billing enabled. If you already have one, skip to **2.3**.

**Via the Console (easiest):**

1. Go to <https://console.cloud.google.com/projectcreate>.
2. **Project name**: e.g. `ProtectPortal Production`.
3. **Project ID**: GCP auto-generates one (e.g. `protectportal-prod-123456`). Note it down — Terraform will need it.
4. **Organisation / Location**: pick yours, or leave "No organisation" for a personal Google account.
5. Click **Create**.

**Via gcloud (if you already authenticated):**

```powershell
gcloud projects create protectportal-prod-$([System.Guid]::NewGuid().ToString().Substring(0,6)) `
    --name="ProtectPortal Production"
```

Note the project ID it prints — you will use it in every subsequent command.

### 2.2 Enable billing on the project

Billing **must** be linked before any of the APIs the bootstrap script enables will work.

1. Go to <https://console.cloud.google.com/billing/linkedaccount>.
2. Select your project (top of the page, project picker).
3. Click **Link a billing account** → choose an existing billing account or create one.

> If you don't have a billing account yet, create one at <https://console.cloud.google.com/billing/create>. New accounts get a $300 / 90-day free trial (with Google account verification).

**Verify in PowerShell:**

```powershell
gcloud beta billing projects describe YOUR_PROJECT_ID
```

You should see `billingEnabled: true`. If it says `false`, billing is not linked yet — Terraform will fail.

### 2.3 Grant yourself the right IAM roles

If you created the project, you already have `roles/owner`. Skip this section.

If someone else owns the project, ask them to grant you these roles:

```powershell
# Run by the project Owner:
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID `
    --member="user:you@example.com" `
    --role="roles/owner"
```

Or, if you want least-privilege instead of Owner, the bootstrap + Terraform need:

- `roles/serviceusage.serviceUsageAdmin` (enable APIs)
- `roles/storage.admin` (state bucket)
- `roles/compute.admin` (VMs, network, LB)
- `roles/iam.serviceAccountAdmin` + `roles/iam.serviceAccountUser` (per-VM SAs)
- `roles/monitoring.admin` + `roles/logging.admin`
- `roles/iap.admin` (optional, for SSH access setup)
- `roles/resourcemanager.projectIamAdmin` (to grant the VM SAs their roles)

### 2.4 (Optional) Request quota for N2 vCPUs

The production VM uses `n2-standard-16` = **16 vCPUs**. Brand-new projects sometimes have a regional N2 quota of 8 or 12 — apply will fail with `quotaExceeded`.

**Check:**

```powershell
gcloud compute project-info describe --project=YOUR_PROJECT_ID `
    --format="value(quotas)" | Select-String "N2_CPUS"
```

**If the limit is under 20**, request an increase:

1. Go to <https://console.cloud.google.com/iam-admin/quotas>.
2. Filter by **Service: Compute Engine API**, **Metric: `N2 CPUs`**, **Region: `asia-southeast1`**.
3. Tick the row → **Edit Quotas** → request `20` or higher.
4. Approval takes minutes to hours.

### 2.5 (Required for production sizing) Request quota for regional SSD storage

The production VM's data disk is **2 TB `pd-ssd`** plus 50 GB SSD boot disks on both VMs — that's `2048 + 50 + 50 = 2148` GB of SSD in `asia-southeast1`. Brand-new projects are typically capped at **500 GB**, which produces this error during `terraform apply`:

```
Error: Error waiting to create Disk: Error waiting for Creating Disk:
Quota 'SSD_TOTAL_GB' exceeded.  Limit: 500.0 in region asia-southeast1.
      metric name = compute.googleapis.com/ssd_total_storage
      limit name = SSD-TOTAL-GB-per-project-region
      limit = 500
      dimensions = map[region:asia-southeast1]

  with google_compute_disk.prod_data[0]
```

**Check:**

```powershell
gcloud compute project-info describe --project=YOUR_PROJECT_ID `
    --format="value(quotas)" | Select-String "SSD_TOTAL_GB"
```

Or in the Console: <https://console.cloud.google.com/iam-admin/quotas?project=YOUR_PROJECT_ID> → filter **Service: Compute Engine API**, **Metric: `Persistent Disk SSD (GB)`**, **Region: `asia-southeast1`**.

**Required limit** (for the spec'd production sizing):

| Setting | SSD GB needed |
| --- | --- |
| `prod_boot_disk_size_gb = 50`, `prod_boot_disk_type = "pd-ssd"` | 50 |
| `prod_data_disk_size_gb = 2048`, `prod_data_disk_type = "pd-ssd"` | 2048 |
| `dr_boot_disk_size_gb = 50`, `dr_boot_disk_type = "pd-ssd"` | 50 |
| `dr_data_disk_size_gb = 500`, `dr_data_disk_type = "pd-standard"` (HDD, not SSD) | 0 |
| **Total SSD in `asia-southeast1`** | **2148** |

**Request at least 3000** to leave headroom for snapshots-restored-as-disks during DR drills, image builds (boot disk gets snapshotted), and ad-hoc resizes:

1. Same Quotas page in the Console.
2. Filter → **Persistent Disk SSD (GB)** → **asia-southeast1** → tick the row.
3. Click **EDIT QUOTAS** at the top.
4. Enter `3000` (or higher) and a one-line justification (e.g. "ProtectPortal production VM uses 2 TB pd-ssd data disk per procurement spec").
5. Submit. Approval is usually minutes for reasonable bumps, sometimes a few hours for larger asks.

**If you can't get the quota approved** (e.g. trial-account caps), set `prod_data_disk_type = "pd-balanced"` in `prod.tfvars` instead — `pd-balanced` is a separate quota (`SSD_BALANCED_TOTAL_GB`) and is typically more available. Performance is ~40% lower than `pd-ssd` but adequate for most application workloads.

### 2.6 (Optional) Request quota for HDD storage

The DR VM's 500 GB data disk is `pd-standard` (HDD). The default `pd-standard` quota in a new project is usually generous (e.g. 50 TB), but worth a quick check:

```powershell
gcloud compute project-info describe --project=YOUR_PROJECT_ID `
    --format="value(quotas)" | Select-String "DISKS_TOTAL_GB"
```

If under 1000, request an increase to 2000 via the same Console flow — metric name **Persistent Disk Standard (GB)**.

---

## 3. Authenticate locally

There are **two** logins. Both are required.

### 3.1 User login (for `gcloud` commands)

```powershell
gcloud auth login
```

A browser opens. Pick the Google account that has access to the project. After confirming, the browser shows "You are now authenticated."

```powershell
gcloud config set project YOUR_PROJECT_ID
gcloud auth list
```

The active account should be marked with `*`.

### 3.2 Application-default credentials (for Terraform)

Terraform does **not** use the `gcloud auth login` session. It reads a separate credential file written by:

```powershell
gcloud auth application-default login
```

Another browser flow opens. Use the same account.

**Verify the file exists:**

```powershell
Test-Path "$env:APPDATA\gcloud\application_default_credentials.json"
```

Should print `True`. If it prints `False`, repeat the command.

> **Heads-up:** This file is a long-lived OAuth refresh token. Treat it like a password — don't share your machine while logged in, and run `gcloud auth application-default revoke` if it leaks.

---

## 4. Domain / DNS

The Google-managed SSL certificate validates by DNS — it will sit in `PROVISIONING` forever if the domain doesn't resolve to the load balancer IP.

You need:

- [ ] A registered domain (e.g. `example.com`) or subdomain (e.g. `portal.example.com`) you can edit DNS records on.
- [ ] Access to the DNS provider for that domain (Cloudflare, Route 53, GoDaddy, Cloud DNS, etc.).

**No action required yet** — the DNS A record gets created **after** `terraform apply` outputs the load balancer IP. Just make sure you'll have access at that point.

**Option:** If your domain is already in **Cloud DNS** in the same GCP project, you can let Terraform create the A record by setting `create_dns_record = true` and `dns_managed_zone = "..."` in `terraform.tfvars`. To check:

```powershell
gcloud dns managed-zones list
```

If your zone is listed, note its name for later.

---

## 5. Alert email

Cloud Monitoring will send alerts to **one email address** (configurable later — variable `alert_email`).

Use a shared inbox or distribution list, not an individual mailbox.

> The first alert email from Google Cloud requires you to click a confirmation link. Have access to that inbox before deploying.

---

## 6. Image choice (decide your deployment path)

Each VM can boot from one of three sources:

| Path | Variable in tfvars | What you need before `terraform apply` |
| --- | --- | --- |
| **Default Ubuntu LTS** | leave `prod_disk_image` / `prod_machine_image` empty | Nothing extra. The public `ubuntu-os-cloud/ubuntu-2204-lts` image is always available. |
| **Custom disk image (your project)** | `prod_disk_image = "<project>/<image>"` or `<project>/family/<family>` | The image must exist. Build via `scripts/build-shared-image.ps1` (see `docs/SHARED-IMAGE-GUIDE.md`). |
| **Custom disk image (shared from another project)** | `prod_disk_image = "projects/<other>/global/images/<name>"` | The image **and** an IAM grant from the owner — see below. |
| **Machine image (your project)** | `prod_machine_image = "projects/<this>/global/machineImages/<name>"` | A machine image captured via Console (Compute Engine → Machine images → Create) or `gcloud beta compute machine-images create ...`. |
| **Machine image (shared)** | `prod_machine_image = "projects/<other>/global/machineImages/<name>"` | Machine image + IAM grant from owner. |

You can mix per VM — e.g. prod from a machine image, DR from a disk image.

### 6.1 Decision: does the image carry the data disk?

When you use any custom image, the next question is whether that image already includes the data disk:

| | Set in tfvars |
| --- | --- |
| Image is OS/boot only — you want our managed data disk | `prod_create_data_disk = true` (the default) |
| Image is a whole VM snapshot that already includes the data disk | `prod_create_data_disk = false` |

Setting `false` skips creating the `google_compute_disk.prod_data`, the attachment, the snapshot policy binding, and the mount script. The image's own data disk + fstab handle everything.

> **Don't pick the wrong one.** If you set `create_data_disk = true` but the image already carries a data disk, you'll get a `device_name` collision at apply time. If you set `create_data_disk = false` but the image doesn't carry one, `/data` (or `/backups`) won't exist on the VM at all.
>
> Inspect the image first if unsure:
>
> ```powershell
> # For a machine image:
> gcloud beta compute machine-images describe <NAME> --project=<PROJECT> `
>     --format="value(sourceInstanceProperties.disks[].deviceName.list(),sourceInstanceProperties.disks[].boot.list())"
> # If you see two device names with boot values true;false, the image has both
> # a boot AND a data disk -- set create_data_disk = false.
> ```

### 6.2 Decision: trust the image's VM settings, or override?

For machine images only, there's one more toggle:

| | Set in tfvars |
| --- | --- |
| Override the MI's machine_type, scheduling, Shielded VM settings | `prod_inherit_from_machine_image = false` (the default) |
| Use the MI's captured values for those fields | `prod_inherit_from_machine_image = true` |

Either way, network / IAM / firewall tags / OS Login metadata are **always** overridden because they reference resources in your project.

### 6.3 (Only for shared images) IAM grant from the image owner

If the disk image or machine image lives in another GCP project, the owner must grant `roles/compute.imageUser` to:

1. Your operator account (the one running `terraform apply`)
2. Your project's Compute Engine service agent: `service-<PROJECT_NUMBER>@compute-system.iam.gserviceaccount.com`

Get your project number:

```powershell
gcloud projects describe YOUR_PROJECT_ID --format="value(projectNumber)"
```

Send those two principals to the image owner. See `docs/SHARED-IMAGE-GUIDE.md` → "Using an image shared by another GCP account / project" for the exact `gcloud compute images add-iam-policy-binding` commands they'd run.

**Verify the grant works** before changing your tfvars:

```powershell
# Disk image:
gcloud compute images describe <IMAGE_NAME> --project=<OWNER_PROJECT> `
    --format="value(name,status)"

# Machine image:
gcloud beta compute machine-images describe <MI_NAME> --project=<OWNER_PROJECT> `
    --format="value(name,status)"
```

If either errors with `403`, the grant isn't in place. Don't proceed.

---

## 7. Final verification

Run this in PowerShell. All checks should succeed:

```powershell
# --- Tooling
terraform version
gcloud --version | Select-Object -First 1

# --- Authenticated
gcloud auth list --filter="status:ACTIVE" --format="value(account)"
Test-Path "$env:APPDATA\gcloud\application_default_credentials.json"

# --- Project + billing
$proj = gcloud config get-value project
Write-Host "Active project: $proj"
gcloud beta billing projects describe $proj --format="value(billingEnabled)"
```

Expected:

```
Terraform v1.6.x (or newer)
Google Cloud SDK 490.x.x (or newer)
you@example.com
True
Active project: your-project-id
True
```

### Image availability check (only if you set a custom image in tfvars)

If you set `prod_disk_image` to a disk image:

```powershell
# Replace the value with what you set in tfvars; this is just the resolution check
gcloud compute images describe <IMAGE_NAME> --project=<IMAGE_PROJECT> `
    --format="value(name,status,family)"
# Status should read READY.
```

If you set `prod_machine_image` to a machine image:

```powershell
gcloud beta compute machine-images describe <MI_NAME> --project=<MI_PROJECT> `
    --format="value(name,status,sourceInstanceProperties.disks[].deviceName.list())"
# Status should read READY. The disks list tells you whether the MI carries
# a data disk (matters for the create_data_disk decision in 6.1).
```

Repeat with the DR equivalents if you set per-VM values.

If all checks pass, you are ready to run the bootstrap script:

```powershell
.\scripts\bootstrap.ps1 -ProjectId (gcloud config get-value project)
```

Then follow the on-screen next steps — they are also documented in [DEPLOYMENT.md](DEPLOYMENT.md).

---

## Troubleshooting

### `googleapi: Error 403 ... compute.images.useReadOnly` during apply

The shared image is missing one of the two principal grants. Re-check that the image owner granted `roles/compute.imageUser` to BOTH your operator account AND your project's `service-<NUMBER>@compute-system.iam.gserviceaccount.com` service agent (per Section 6.3).

### `device_name 'protectportal-prod-data' is already used by another disk` during apply

The machine image already contains a disk with that device name AND you have `prod_create_data_disk = true`. Pick one:
- Flip `prod_create_data_disk = false` and let the MI's disk be the live one.
- OR rebuild the MI from a source VM that had the data disk detached.

### `/data` (or `/backups`) doesn't exist on the VM after apply

You set `*_create_data_disk = false` but the image you used doesn't actually carry a data disk. Either:
- Flip `*_create_data_disk = true` so Terraform creates and mounts one.
- OR build a new image from a source VM that has the data disk in fstab.

### `googleapi: Error 400 ... 'resource.disks[0].initializeParams.sourceImage'`

The `prod_disk_image` or `dr_disk_image` value isn't a valid GCE image reference. Valid forms:

- `<project>/<image-name>` (e.g. `iacat-test/ppt-test-base-202606031452`)
- `<project>/family/<family-name>`
- `projects/<project>/global/images/<image-name>` (long form)
- `projects/<project>/global/images/family/<family-name>` (long form, family)

### "The term 'gcloud' is not recognized"

The SDK installer adds gcloud to PATH but only for **new** shells. Close all PowerShell windows and open a fresh one. If that still fails, manually add `C:\Users\<you>\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin` to PATH.

### "The term 'terraform' is not recognized"

Same fix as above for the manual install. If you installed via winget, sign out and back in once to refresh the system PATH.

### `gcloud auth login` opens the browser but hangs

You may be behind a corporate proxy that blocks the OAuth callback to `localhost`. Use the manual flow:

```powershell
gcloud auth login --no-launch-browser
```

It prints a URL. Open it in any browser, copy the verification code back into the terminal.

### `application-default login` fails with `invalid_grant`

Your machine clock is skewed. Sync time:

```powershell
w32tm /resync
```

### Billing not enabled even after linking

Linking takes ~1 minute to propagate. Re-run the verify command. If it still says `false` after 5 minutes, check that you have `roles/billing.user` on the billing account.

### "Project YOUR_PROJECT_ID has not enabled API ..."

The bootstrap script enables APIs — don't try to apply Terraform before running it. If you're re-running after destroy and getting this error, re-run the bootstrap script.

### "You do not currently have an active account selected"

`gcloud auth login` was never run, or the session expired. Re-run it.

### Behind a corporate firewall blocking *.googleapis.com

You will need an outbound proxy whitelist for at least:

- `*.googleapis.com`
- `accounts.google.com`
- `oauth2.googleapis.com`
- `storage.googleapis.com`

If that's not possible, run Terraform from Google Cloud Shell instead — it sits inside Google's network and avoids the issue. Open <https://shell.cloud.google.com>, clone the repo there, and continue from step 5.
