# Test Run Guide — `iacat-test`

Step-by-step procedure to deploy the ProtectPortal stack into the **`iacat-test`** sandbox GCP project with absolute-minimum sizing, verify it works, and tear it down cleanly.

| | |
| --- | --- |
| **Sandbox project** | `iacat-test` |
| **Test domain** | `iacat-test.quanbyit.com` |
| **Alert inbox** | `devops@quanbyit.com` |
| **Region / zones** | `asia-southeast1` / `-a` (prod), `-b` (DR) |
| **Cost while running** | ~$0.06 / hour (~$42 / month) |
| **Cost when destroyed** | ~$0 |

---

## 0. One-time prerequisites

If you have **not** run through [`PREREQUISITES.md`](PREREQUISITES.md) on this machine, do that first. The 30-second sanity check:

```powershell
terraform version                                              # >= 1.6.0
gcloud --version | Select-Object -First 1                      # Google Cloud SDK ...
gcloud auth list --filter="status:ACTIVE" --format="value(account)"
Test-Path "$env:APPDATA\gcloud\application_default_credentials.json"
```

All four must succeed before continuing. If application-default credentials are missing, run `gcloud auth application-default login`.

---

## 1. Confirm the sandbox project + billing

```powershell
# Sandbox project exists and you can access it
gcloud projects describe iacat-test --format="value(projectId,lifecycleState)"

# Billing is linked (Terraform — and every API enablement — fails loudly otherwise)
gcloud beta billing projects describe iacat-test --format="value(billingEnabled)"
```

Expect `iacat-test ACTIVE` and `True`.

If `gcloud beta billing` complains about needing components, accept the install. If it then errors with `Cloud Billing API has not been used in project ... before or it is disabled`, that's actually telling you billing is **not linked** at all — go link it:

<https://console.cloud.google.com/billing/linkedaccount?project=iacat-test>

Click "Link a billing account", pick your account, click "Set account", then re-run the billing check until it prints `True`. **Do not skip this** — without it, step 2's bootstrap will fail with an opaque `PERMISSION_DENIED` on every API.

---

## 2. Bootstrap the project

This enables every API the stack needs, creates the Terraform state bucket, and writes a `.env.gcp.ps1` helper at the repo root.

```powershell
.\scripts\bootstrap.ps1 -ProjectId iacat-test
```

When it finishes you'll see:

```
Active project   : iacat-test
State bucket     : gs://iacat-test-tfstate
State prefix     : protectportal/prod        <-- we override this in step 3
Region           : asia-southeast1
```

> The bootstrap defaults to the `protectportal/prod` state prefix. We override to a **test prefix** in the next step so the test deploy keeps its state separate from any future production deploy.

Load the env helper into the current shell:

```powershell
. .\.env.gcp.ps1
```

---

## 3. Initialize Terraform with a dedicated test state prefix

```powershell
terraform init `
    -reconfigure `
    -backend-config="bucket=iacat-test-tfstate" `
    -backend-config="prefix=protectportal/test"
```

`-reconfigure` is important — it tells Terraform to overwrite the prefix the bootstrap script printed without complaining about migrating state.

Successful init prints `Terraform has been successfully initialized!`

---

## 4. Verify `test.tfvars` is filled in

The file is already filled in for this run:

```hcl
project_id  = "iacat-test"
domain_name = "iacat-test.quanbyit.com"
alert_email = "devops@quanbyit.com"
name_prefix = "ppt-test"
environment = "test"
# ... e2-micro VMs, 10 GB pd-standard disks ...
```

Just sanity-check it before applying:

```powershell
Select-String -Path test.tfvars -Pattern "^(project_id|domain_name|alert_email|name_prefix)\s*="
```

---

## 5. Plan

```powershell
terraform plan -var-file test.tfvars -out tfplan
```

> Use the **space-separated** form (`-var-file test.tfvars`). PowerShell's argument parser can mangle the `-var-file=test.tfvars` form so Terraform reads it as a positional working-directory argument and rejects it with "Too many command line arguments."

Read the bottom-line `Plan:` summary — with the test defaults (`enable_https = false`, `enable_snapshot_schedule = false`) expect roughly **30-35 resources to add, 0 to change, 0 to destroy**. With HTTPS turned on it's closer to 40.

Spot-check the plan output for these lines (Ctrl+F in the terminal):

- `machine_type   = "e2-micro"` — appears twice (prod + DR)
- `size           = 10` — boot and data disks
- `type           = "pd-standard"` — boot and data disks
- `name           = "ppt-test-prod"` and `name = "ppt-test-dr"`
- `deletion_protection = false`
- The Cloud Armor rules are present (these don't depend on HTTPS)
- The managed SSL cert is **absent** when `enable_https = false` (default in `test.tfvars`)

If anything looks wrong, fix `test.tfvars` and re-run plan.

---

## 6. Apply

```powershell
terraform apply tfplan
```

End-to-end runtime: **~5 minutes**. The two VMs come up in ~2 minutes; the LB, Cloud Armor policy, and forwarding rules add the rest.

If apply errors with `quotaExceeded` for `IN_USE_ADDRESSES` or `CPUS`, request a quota bump in `asia-southeast1` (the limits on brand-new projects are sometimes very low). Re-run `terraform apply tfplan`.

When apply finishes, capture the outputs:

```powershell
terraform output
```

Note the value of `load_balancer_ip` — you will need it in step 7.

---

## 7. (Optional) Point DNS at the load balancer

> **`test.tfvars` ships with `enable_https = false`**, so the managed SSL cert + HTTPS proxy are skipped and the HTTP forwarding rule routes straight to the backend. You can verify the test deploy at `http://<load_balancer_ip>/` without any DNS setup at all. Skip the rest of this step.

If you flipped `enable_https = true` to validate the full HTTPS stack, the Google-managed cert validates by DNS. Until `iacat-test.quanbyit.com` resolves to the LB IP, the cert sits in `PROVISIONING` and HTTPS returns a TLS error.

```powershell
# Print the IP to copy
terraform output -raw load_balancer_ip
```

At your DNS provider for `quanbyit.com`, create:

```
iacat-test.quanbyit.com.   A   <load_balancer_ip>   TTL 300
```

Then wait. The cert provisioning typically completes 15–60 minutes after DNS resolves correctly.

**Check progress:**

```powershell
# Resolve from your laptop
nslookup iacat-test.quanbyit.com

# Cert status (only exists when enable_https = true)
gcloud compute ssl-certificates describe ppt-test-managed-cert --global `
    --format="value(managed.status,managed.domainStatus)"
```

You want both fields to read `ACTIVE` eventually.

---

## 8. Verify the stack works

### 8.1 Both VMs are RUNNING

```powershell
gcloud compute instances list --filter="labels.environment=test" `
    --format="table(name,zone,status,machineType.basename())"
```

Expect:

```
NAME            ZONE                STATUS   MACHINE_TYPE
ppt-test-dr     asia-southeast1-b   RUNNING  e2-micro
ppt-test-prod   asia-southeast1-a   RUNNING  e2-micro
```

### 8.2 SSH into the production VM via IAP

```powershell
terraform output -raw ssh_via_iap_prod | Invoke-Expression
```

Once inside:

```bash
# Boot + data disk both mounted
df -h | grep -E '/$|/data'

# Ops Agent (logs + metrics) running
systemctl is-active google-cloud-ops-agent

# nginx serving on :80
systemctl is-active nginx
curl -sI http://localhost/ | head -1   # HTTP/1.1 200 OK

# Startup script log
tail -30 /var/log/protectportal-startup.log

exit
```

### 8.3 SSH into the DR VM

```powershell
terraform output -raw ssh_via_iap_dr | Invoke-Expression
```

Inside:

```bash
df -h | grep /backups
systemctl is-active google-cloud-ops-agent
psql --version                 # PostgreSQL 16 client installed
sudo -u postgres psql -c '\l'  # local cluster running, used to restore-validate nightly dumps
exit
```

### 8.4 Hit the load balancer

```powershell
# HTTP — with enable_https = false (default in test.tfvars), this serves
# the backend directly. With enable_https = true it returns a 301 to HTTPS.
curl.exe -sI "http://$(terraform output -raw load_balancer_ip)/" | Select-Object -First 5

# HTTPS — only works when enable_https = true AND the managed cert is ACTIVE.
curl.exe -sI "https://iacat-test.quanbyit.com/" | Select-Object -First 5
```

The HTTPS response should include:

```
HTTP/2 200
strict-transport-security: max-age=63072000; includeSubDomains; preload
x-content-type-options: nosniff
```

### 8.5 Monitoring is alive

Open the Cloud Monitoring dashboard:

```powershell
Start-Process "https://console.cloud.google.com/monitoring/dashboards?project=iacat-test"
```

Look for the `ppt-test Overview` dashboard. CPU / memory / disk charts will start populating within ~2 minutes of VM boot.

Confirm the email notification channel:

```powershell
gcloud alpha monitoring channels list --filter="displayName:ppt-test" `
    --format="value(displayName,labels.email_address,verificationStatus)"
```

If `verificationStatus` is `UNVERIFIED`, click the confirmation link Google emailed `devops@quanbyit.com` when the channel was first created. Alerts won't fire until verified.

---

## 9. Tear down

When you're done validating, run these in order. The first `destroy` fails on the two data disks (they have `lifecycle { prevent_destroy = true }`, which is a Terraform meta-argument and cannot be variable-driven — production wants this guard). Drop them out of state, delete with gcloud, then re-run:

```powershell
# 1. First destroy attempt — fails on the two data disks (expected)
terraform destroy -var-file test.tfvars -auto-approve

# 2. Remove the disks from Terraform state
terraform state rm 'google_compute_disk.prod_data' 'google_compute_disk.dr_data'

# 3. Delete the orphaned disks
gcloud compute disks delete ppt-test-prod-data --zone=asia-southeast1-a --project=iacat-test --quiet
gcloud compute disks delete ppt-test-dr-data   --zone=asia-southeast1-b --project=iacat-test --quiet

# 4. Re-run destroy — everything else goes
terraform destroy -var-file test.tfvars -auto-approve
```

### Verify nothing was left behind

```powershell
gcloud compute instances list --project=iacat-test
gcloud compute disks list --project=iacat-test
gcloud compute forwarding-rules list --project=iacat-test
gcloud compute addresses list --project=iacat-test
```

All four should return empty (or only show resources you knowingly kept outside this Terraform). The state bucket `iacat-test-tfstate` and the audit-log bucket stay — that's intentional. Delete them by hand if you want the project completely clean:

```powershell
gcloud storage rm -r gs://iacat-test-tfstate
# Audit bucket: name has a random suffix — list first
gcloud storage buckets list --filter="name:iacat-test-ppt-test-audit*"
```

> Audit bucket has a 1-day WORM retention policy. If `rm -r` fails, wait 24 h after the last object was written and retry.

---

## 10. Going from test → production

Once the test passes:

1. **Different project** for production. Re-run `bootstrap.ps1 -ProjectId <prod-project-id>` against it.
2. **Different state prefix** — the bootstrap script defaults to `protectportal/prod`, which is what you want for production. (Test used `protectportal/test`.)
3. **Different tfvars** — use `terraform.tfvars` (copy from `terraform.tfvars.example` and fill in production values). **Do not pass `-var-file test.tfvars`** — that's the small-sizing override.
4. **Re-init**:
   ```powershell
   terraform init -reconfigure `
       -backend-config="bucket=<prod-project>-tfstate" `
       -backend-config="prefix=protectportal/prod"
   ```
5. **Plan + apply** without `-var-file` so production defaults apply.

---

## Reference — what `test.tfvars` overrides

| Setting | Production default | Test override |
| --- | --- | --- |
| `prod_machine_type` | `n2-standard-16` (16 vCPU / 64 GB) | `e2-micro` (2 vCPU shared / 1 GB) |
| `dr_machine_type` | `n2-custom-4-8192` (4 vCPU / 8 GB) | `e2-micro` |
| `prod_boot_disk_size_gb` | 50 | 10 |
| `prod_boot_disk_type` | `pd-ssd` | `pd-standard` |
| `prod_data_disk_size_gb` | 2048 | 10 |
| `prod_data_disk_type` | `pd-ssd` | `pd-standard` |
| `dr_boot_disk_size_gb` | 50 | 10 |
| `dr_boot_disk_type` | `pd-ssd` | `pd-standard` |
| `dr_data_disk_size_gb` | 500 | 10 |
| `dr_data_disk_type` | `pd-standard` | `pd-standard` |
| `name_prefix` | `protectportal` | `ppt-test` |
| `environment` | `prod` | `test` |
| `enable_deletion_protection` | `true` | `false` |
| `enable_snapshot_schedule` | `true` | `false` |
| `enable_https` | `true` | `false` |

Architecture is identical otherwise — same VPC, firewall, IAM, backend service, Cloud Armor, monitoring. With `enable_https = false` the HTTPS proxy, managed SSL cert, SSL policy, and HTTPS forwarding rule are skipped, and the HTTP forwarding rule points at the backend directly instead of at the redirect URL map.

---

## Troubleshooting

### Ops Agent restarts every few minutes on `e2-micro`

1 GB of RAM is genuinely tight. Bump to `e2-small` (2 GB) in `test.tfvars`:

```hcl
prod_machine_type = "e2-small"
dr_machine_type   = "e2-small"
```

`terraform apply -var-file test.tfvars`. The VM stops, resizes, and restarts in ~90 seconds. Cost goes from ~$14/mo to ~$26/mo combined — still ~95% cheaper than production.

### Managed SSL cert stuck in PROVISIONING

The cert validates by DNS. Check `nslookup iacat-test.quanbyit.com` returns the LB IP. If DNS is correct, give it another 30 minutes — first issuance is slower than renewals. If you don't actually need HTTPS for the test, ignore it.

### `terraform destroy` hangs on `google_compute_security_policy.waf`

Cloud Armor sometimes lags during destroy when forwarding rules still hold a reference. Wait 60 seconds and re-run `terraform destroy`. It converges.

### Bootstrap script complains "project not found"

`iacat-test` doesn't exist or you don't have access. Create it:

```powershell
gcloud projects create iacat-test --name="IACAT Test"
```

Then link billing (`https://console.cloud.google.com/billing/linkedaccount?project=iacat-test`) and re-run the bootstrap.

### Apply error: `Error 403: ... has not been used in project iacat-test before or it is disabled`

The bootstrap script enables the right APIs but enablement is eventually consistent. Wait 60 seconds and re-run `terraform apply tfplan`.

### Wrong project active when running gcloud commands

```powershell
gcloud config set project iacat-test
. .\.env.gcp.ps1
```

The env helper sets `GOOGLE_CLOUD_PROJECT` and `TF_VAR_project_id` so Terraform can't accidentally target the wrong project.
