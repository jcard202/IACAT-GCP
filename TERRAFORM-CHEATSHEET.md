# Terraform Commands and Workflow (ProtectPortal)

This guide is for engineers operating the ProtectPortal Terraform stack against the `iacat-test` and `iacat-prod` projects. It documents the day-to-day inner loop, the most common `terraform` subcommands, how state is structured in GCS, and how to recover from the failure modes we have actually hit. It complements `PREREQUISITES.md` (toolchain and access setup), `DEPLOYMENT.md` (end-to-end deploy procedure), `TESTING.md` (post-deploy validation), and `HTTPS-SETUP.md` (load balancer and managed SSL specifics).

## Table of contents

- [Daily workflow](#daily-workflow)
- [Core commands](#core-commands)
- [State management](#state-management)
- [Recovery and troubleshooting](#recovery-and-troubleshooting)
- [Cheat sheet](#cheat-sheet)

## Daily workflow

The standard inner loop while iterating on the ProtectPortal Terraform stack is **edit → fmt → validate → plan → apply**. Each step is cheap on its own, and skipping the early ones tends to surface as ugly diffs or cryptic errors in `plan`.

### Edit, then format and validate

After editing any `.tf` file, run formatting and a static check before you spend time on a plan:

```powershell
terraform fmt -recursive
terraform validate
```

`terraform fmt` rewrites files to canonical style so diffs stay small and review-friendly. Run it on every save, or at minimum before every commit. `terraform validate` is a fast, offline syntax + type check — it catches missing variables, bad references, and wrong attribute types without touching GCP. See [Core commands](#core-commands) for the full flag list.

### Plan against the right environment

Always plan with an explicit `-var-file` (see [Core commands](#core-commands) for why the space form is required on PowerShell) and write the plan to disk:

```powershell
terraform plan -var-file test.tfvars -out tfplan.test
```

The `-out` file captures the *exact* set of changes Terraform intends to make. Applying that saved plan (instead of re-planning at apply time) guarantees you apply what you reviewed — no drift between the diff you read and the actions Terraform takes. It also lets you hand the plan to a teammate or paste its summary into a PR.

Before running `apply`, scroll to the bottom of the plan output and read the summary line:

```
Plan: 2 to add, 1 to change, 0 to destroy.
```

If `destroy` is non-zero, stop and re-read the diff — the `google_compute_disk.prod_data` and `.dr_data` resources have `prevent_destroy = true` for a reason, and any unexpected destroy is the signal that something is wrong (wrong env, renamed resource, deleted block).

```powershell
terraform apply tfplan.test
```

### Switching environments

The same working directory backs both `iacat-test` and `iacat-prod`, so switching environments means re-pointing the backend:

```powershell
terraform init -reconfigure `
  -backend-config="bucket=iacat-prod-tfstate" `
  -backend-config="prefix=protectportal/prod"
```

To go back to sandbox, swap in `iacat-test-tfstate` / `protectportal/test`. **Immediately after every `init -reconfigure`, confirm the env:**

```powershell
terraform state list
```

If the resources listed don't match what you expect for that environment (e.g., you see prod disks while intending to work on test), do not run `plan` or `apply` — re-run `init -reconfigure` with the right backend config.

### Reading deployed values

Use `terraform output` to retrieve values for current state without re-planning:

```powershell
terraform output                       # all outputs
terraform output load_balancer_ip      # single value
terraform output -raw ssh_via_iap_prod # unquoted, pipeable
```

This is how you grab the load balancer IP to hit the portal, or the ready-made `gcloud compute ssh` command for the prod VM, without digging through the console.

## Core commands

### `terraform init`
Initializes the working directory: downloads providers, configures the backend, and installs modules. Run after cloning, after changing backend config, or after bumping provider versions.

- `-reconfigure` — discard cached backend config and re-prompt (use when switching between `test` and `prod` state).
- `-backend-config="key=value"` — override backend settings inline instead of editing `versions.tf`.
- `-upgrade` — pull newer provider/module versions allowed by your version constraints.

```powershell
terraform init -reconfigure `
  -backend-config="bucket=iacat-test-tfstate" `
  -backend-config="prefix=protectportal/test"
```

### `terraform fmt`
Rewrites `.tf` files to canonical HCL style.

- `-recursive` — descend into subdirectories (modules).
- `-check` — exit non-zero if files would change; perfect for CI.

```powershell
terraform fmt -recursive -check
```

### `terraform validate`
Static check that the config is internally consistent (types, references, required args). Requires `init` first but does not touch state or cloud APIs.

```powershell
terraform validate
```

### `terraform plan`
Produces an execution plan diffing desired config against state.

- `-var-file <file>` — load variables (PowerShell needs the space form, not `=`).
- `-out <file>` — save a binary plan for a guaranteed-identical apply.
- `-target=<addr>` — restrict the plan to one resource (use sparingly).
- `-refresh-only` — detect drift without proposing config changes.

```powershell
terraform plan -var-file test.tfvars -out test.tfplan
terraform plan -var-file prod.tfvars -refresh-only
terraform plan -var-file test.tfvars `
  -target=google_compute_global_forwarding_rule.https
```

### `terraform apply`
Executes a plan against the cloud.

- `-var-file <file>` — same as plan; omit if you saved a plan file.
- `-auto-approve` — skip the interactive yes/no prompt (CI / scripted runs).
- `-replace=<addr>` — force destroy+recreate of one resource (modern `taint`).
- `-target=<addr>` — apply only one resource.

```powershell
terraform apply test.tfplan
terraform apply -var-file prod.tfvars -auto-approve
terraform apply -var-file test.tfvars `
  -replace=google_compute_instance.prod
```

### `terraform destroy`
Tears down everything in the current state.

- `-var-file <file>` — required so destroy can re-evaluate config.
- `-auto-approve` — non-interactive.
- `-target=<addr>` — destroy one resource only.

Note: `google_compute_disk.prod_data` and `.dr_data` have `lifecycle { prevent_destroy = true }`, so a blanket destroy will fail until you `terraform state rm` those disks first (see [State management](#state-management)).

```powershell
terraform destroy -var-file test.tfvars
terraform destroy -var-file test.tfvars `
  -target=google_compute_managed_ssl_certificate.portal
```

### `terraform output`
Reads outputs from state — handy for piping into other tools.

- `-raw` — emit a single value with no quotes/JSON wrapping (good for shell vars).
- `-json` — emit all outputs as machine-readable JSON.

```powershell
$ip = terraform output -raw load_balancer_ip
terraform output -json | ConvertFrom-Json
```

### `terraform show`
Pretty-prints either current state or a saved plan file. Use to review a plan before applying, or to inspect drift.

```powershell
terraform show test.tfplan
terraform show -json test.tfplan | ConvertFrom-Json
```

### `terraform console`
Interactive REPL evaluating expressions against current state — invaluable for debugging `for_each`, interpolations, or output shapes before committing them to config. Press `Ctrl+D` (or type `exit`) to quit.

```powershell
terraform console -var-file test.tfvars
> google_compute_disk.prod_data.size
> var.enable_https ? "https on" : "http only"
> [for k, v in google_compute_instance.prod.network_interface[0].access_config : v.nat_ip]
```

## State management

Terraform state is the source of truth that maps your HCL resources (e.g. `google_compute_disk.prod_data`) to real GCP objects (project, zone, self-link, generation). Without it, Terraform cannot tell a create from an update from a no-op. For ProtectPortal the state lives in GCS rather than on disk so that the sandbox and prod state are shareable across machines, locked during `apply` (GCS object generations provide mutual exclusion), and versioned — every write produces a new object generation you can roll back to.

Backends in use:

- `gs://iacat-test-tfstate` prefix `protectportal/test`
- `gs://iacat-prod-tfstate` prefix `protectportal/prod`

### Inspecting state

```powershell
terraform state list
terraform state list | Select-String "prod_data"
terraform state show google_compute_disk.prod_data
terraform state show google_compute_instance.prod
```

`state list` confirms which addresses Terraform is currently tracking; `state show` dumps the cached attributes (zone, size, source image, labels) for one resource.

### Removing without destroying

`prevent_destroy = true` on `google_compute_disk.prod_data` / `.dr_data` blocks `terraform destroy`. To tear the rest of the stack down while keeping the data disk intact, drop the disk from state first:

```powershell
terraform state rm google_compute_disk.prod_data
terraform state rm google_compute_disk.dr_data
terraform destroy -var-file prod.tfvars
```

The disks remain in GCP, just unmanaged. Re-adopt them later with `terraform import`.

### Renaming

If you rename `google_compute_instance.prod` to `google_compute_instance.prod_app` in HCL, move it in state instead of destroy/recreate:

```powershell
terraform state mv google_compute_instance.prod google_compute_instance.prod_app
```

### Importing an existing GCP resource

Adopt a disk that already exists (e.g. after a `state rm`):

```powershell
terraform import -var-file prod.tfvars `
  google_compute_disk.prod_data `
  projects/iacat-prod/zones/asia-southeast1-a/disks/protectportal-prod-data
```

For an instance:

```powershell
terraform import -var-file prod.tfvars `
  google_compute_instance.prod `
  projects/iacat-prod/zones/asia-southeast1-a/instances/protectportal-prod
```

### Refreshing

To reconcile state with what GCP actually has (someone resized a disk in the console, a managed SSL cert flipped to `ACTIVE`) without applying any HCL changes:

```powershell
terraform plan -refresh-only -var-file prod.tfvars
terraform apply -refresh-only -var-file prod.tfvars
```

`terraform refresh` still works but is deprecated in favour of `-refresh-only`.

### Breaking a stuck lock

If an `apply` crashed mid-run, the next command will error with a `Lock Info` block containing an ID. **Confirm no other operator is mid-apply first** — force-unlocking during a live run corrupts state.

```powershell
terraform force-unlock 1735000000000000
```

### Recovering an older state version

The state buckets have object versioning on. List historical generations and restore the one before the bad write:

```powershell
gcloud storage ls --versions `
  gs://iacat-prod-tfstate/protectportal/prod/default.tfstate

gcloud storage cp `
  "gs://iacat-prod-tfstate/protectportal/prod/default.tfstate#1735000000000000" `
  gs://iacat-prod-tfstate/protectportal/prod/default.tfstate
```

Run `terraform plan -var-file prod.tfvars` immediately afterwards to confirm the restored state matches reality.

## Recovery and troubleshooting

This section catalogs failure modes encountered while operating the ProtectPortal Terraform stack against `iacat-test` and `iacat-prod`, with the exact recovery steps for each.

### `Error: Too many command line arguments`
Windows PowerShell 5.1 mangles the `-var-file=foo.tfvars` equals form, splitting it into two tokens and feeding the trailing path as a positional argument. Always use the **space form**:

```powershell
terraform plan -var-file test.tfvars -out tfplan
terraform apply -var-file prod.tfvars
```

If you need the equals form (e.g. copy-pasting from Linux docs), wrap the whole flag in quotes: `"-var-file=test.tfvars"`. The space form is safer; standardize on it.

### `Error 220002` / `SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED`
Two root causes, both transient-looking:
1. **Billing not linked** to the target project. Run `gcloud beta billing projects describe iacat-test` and link a billing account if `billingEnabled` is false.
2. **API enablement race** — Terraform enabled an API in the same plan and a dependent resource fired before propagation. Wait 30-60 seconds and re-run `terraform apply`. If it persists, enable the API out-of-band with `gcloud services enable <api>.googleapis.com` and re-plan.

### Stale `tfplan` after partial apply
A failed apply mutates real state but leaves your saved plan referencing the pre-apply world. **Never re-apply the same `tfplan`** after a failure — discard it and re-plan:

```powershell
Remove-Item tfplan -ErrorAction SilentlyContinue
terraform plan -var-file test.tfvars -out tfplan
terraform apply tfplan
```

### Destroy blocked by `prevent_destroy` on data disks
`google_compute_disk.prod_data` and `google_compute_disk.dr_data` carry `lifecycle { prevent_destroy = true }` on purpose. To intentionally tear them down:

```powershell
terraform state rm google_compute_disk.prod_data google_compute_disk.dr_data
gcloud compute disks delete ppt-test-prod-data --zone=asia-southeast1-a --project=iacat-test --quiet
gcloud compute disks delete ppt-test-dr-data   --zone=asia-southeast1-b --project=iacat-test --quiet
```

Snapshot first (`gcloud compute disks snapshot ...`) if the data has any value. Do **not** edit the lifecycle block in Terraform just to get through a destroy — that change leaks into future PRs.

### `Error 404: Cannot find metric ... created recently`
Log-based metrics take 30-90 seconds to propagate from Logging to Monitoring. Alert policies referencing a freshly-created metric will 404. Just re-run `terraform apply` — the second pass usually succeeds. If it doesn't, add an explicit `depends_on` or `time_sleep` between the metric and the alert policy.

### Managed SSL cert stuck in `PROVISIONING` or `FAILED_NOT_VISIBLE`
Google's CA cannot complete the domain validation challenge because DNS for the cert's domain isn't pointing at the load balancer's anycast IP. Check:

```powershell
terraform output -raw load_balancer_ip
nslookup iacat-test.quanbyit.com 8.8.8.8
```

Fix the A record at the registrar; the cert flips to `ACTIVE` within 15-60 minutes. There is no Terraform-side fix.

### Cannot delete `google_compute_managed_ssl_certificate.portal` ("in use")
The cert is attached to `google_compute_target_https_proxy.portal`. Terraform's default plan deletes the cert first, which Google rejects. Force a coordinated replacement:

```powershell
terraform apply -var-file test.tfvars `
  -replace=google_compute_managed_ssl_certificate.portal `
  -replace=google_compute_target_https_proxy.portal
```

This rebuilds both in the correct order. Same pattern applies when toggling `enable_https` off then on.

### State lock held by previous run
If a prior `terraform apply` was killed (Ctrl-C, RDP disconnect), the GCS state lock persists. Terraform prints the lock ID in the error — use it verbatim:

```powershell
terraform force-unlock <LOCK_ID>
```

Only force-unlock when you are certain no other apply is running.

### Wrong-environment apply guard
Before any `apply`, confirm which backend prefix is initialized:

```powershell
terraform state list | Select-Object -First 5
```

The state-list resource names (e.g. `protectportal-prod` vs `ppt-test-prod`) and the `gs://iacat-{test,prod}-tfstate` URL in `terraform init` output should match the `-var-file` you're about to pass. If they don't, re-run `terraform init -reconfigure` against the correct backend prefix before applying.

## Cheat sheet

```powershell
terraform fmt -recursive
terraform validate
terraform init -reconfigure -backend-config="bucket=iacat-test-tfstate" -backend-config="prefix=protectportal/test"
terraform plan -var-file test.tfvars -out tfplan.test
terraform apply tfplan.test
terraform state list
terraform state show google_compute_disk.prod_data
terraform output -raw load_balancer_ip
terraform apply -var-file test.tfvars -replace=google_compute_instance.prod
terraform force-unlock <LOCK_ID>
```
