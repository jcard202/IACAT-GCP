# Committed Use Discounts — Purchase and Operations Guide

How to buy, verify, monitor, and renew a resource-based Committed Use Discount (CUD) for the ProtectPortal production VMs.

> **Read this first:** A CUD is a NON-CANCELLABLE multi-year financial commitment. You pay the committed hourly rate for the full term whether or not the matching VMs are running. Do not run the purchase script until you have read this guide and either run the 30-day baseline (recommended) or are very sure of your sizing.

---

## What you're buying

A **resource-based CUD** in `asia-southeast1` for the N2 machine family.

| Default | Value | Source |
| --- | --- | --- |
| Region | `asia-southeast1` | Same region as both VMs |
| Family | `N2` | Both VMs are N2 |
| vCPU | `20` | `n2-standard-16` (16) + `n2-custom-4-8192` (4) |
| Memory | `72` GB | `n2-standard-16` (64) + `n2-custom-4-8192` (8) |
| Term | `1 year` | Lower risk than 3-year |
| Approx discount | ~37% (1yr) / ~55% (3yr) | Google list pricing |

If you committed at these defaults and ran both VMs 24/7 for the full year, the savings would be roughly **$295/month** at 1yr (~$3.5k/yr) or **$437/month** at 3yr (~$15.7k over the full term). Verify with the [calculator](https://cloud.google.com/products/calculator) before purchase.

---

## Procedure

### Step 1 — Run for ~30 days first

A CUD only saves money if your committed capacity matches actual consistent usage. Letting prod run for 30 days gives GCP's optimizer enough data to recommend an exact sizing.

```powershell
# Open the GCP cost-optimization recommendations for iacat-prod
Start-Process "https://console.cloud.google.com/billing/recommendations?project=iacat-prod"
```

Look for the **"Committed use discount analysis"** card. It will tell you exactly which vCPU + memory commitment would have maximised savings over your usage period, and what the projected savings are. **Use those numbers** — they're more accurate than the spec-sheet math.

If you're confident in your sizing and don't want to wait, skip to Step 2. Just know that under- and over-committing both cost money.

### Step 2 — Sanity-check what's currently running

```powershell
gcloud compute instances list --project=iacat-prod `
    --filter="zone:(asia-southeast1) AND machineType.scope(machineTypes):(n2-)" `
    --format="table(name,zone.basename(),machineType.scope(machineTypes),status)"
```

Add up the vCPU and RAM totals; they should match (or be at most slightly higher than) what you're about to commit. If the totals are LOWER than your planned commitment, scale down or shrink the commitment — paying for capacity you don't use is the #1 CUD mistake.

### Step 3 — Dry-run the purchase

The script defaults to dry-run. It validates everything and prints the exact purchase plan **without buying anything**:

```powershell
.\scripts\purchase-cud.ps1 -ProjectId iacat-prod
```

You should see:

```
==> Checking gcloud
    [ok] authenticated as devops@quanbyit.com
==> Verifying project 'iacat-prod'
    [ok] project verified
==> Checking billing is linked
    [ok] billing enabled
==> Checking for an existing commitment named 'protectportal-n2-1yr'
    [ok] no name collision
==> Current N2 usage in asia-southeast1 (informational)
NAME              ZONE               MACHINE_TYPE        STATUS
protectportal-prod  asia-southeast1-a  n2-standard-16      RUNNING
protectportal-dr    asia-southeast1-b  n2-custom-4-8192    RUNNING

============================================================
 Committed Use Discount purchase plan
============================================================

  Project       : iacat-prod
  Region        : asia-southeast1
  Name          : protectportal-n2-1yr
  Machine family: N2   (gcloud type: GENERAL_PURPOSE_N2)
  Term          : 1year   (gcloud plan: twelve-month)
  vCPU          : 20
  Memory        : 72 GB

  This is a NON-CANCELLABLE commitment. ...

============================================================
 DRY RUN -- no commitment was purchased.
 Re-run with -Confirm to actually purchase.
============================================================
```

Confirm:
- Project is `iacat-prod` (NOT `iacat-test`).
- Region matches the actual VM region.
- Term is what you intended.
- vCPU and Memory match what's running.

### Step 4 — Override sizing if needed

Common overrides:

```powershell
# Bigger discount, longer commit (recommended only after 6+ months of stable usage)
.\scripts\purchase-cud.ps1 -ProjectId iacat-prod -Term 3year

# Commit only the prod VM, leave DR on-demand (smaller commitment, less waste if DR sits idle)
.\scripts\purchase-cud.ps1 -ProjectId iacat-prod -VCpu 16 -MemoryGb 64

# Different family / region
.\scripts\purchase-cud.ps1 -ProjectId iacat-prod -MachineFamily e2 -Region asia-east1

# Custom name (if you have multiple commitments)
.\scripts\purchase-cud.ps1 -ProjectId iacat-prod -Name "protectportal-n2-prod-only" -VCpu 16 -MemoryGb 64
```

Re-run dry-run as many times as you like — nothing is purchased until you add `-Confirm`.

### Step 5 — Verify pricing one more time

```powershell
Start-Process "https://cloud.google.com/products/calculator"
```

In the calculator: Compute Engine → N2 → `asia-southeast1` → enter `n2-standard-16` + `n2-custom-4-8192` → toggle 1-year vs 3-year vs on-demand and compare totals. **Don't proceed if the monthly savings is less than you expect**, that usually means the commitment is wrong-shaped.

### Step 6 — Purchase

```powershell
.\scripts\purchase-cud.ps1 -ProjectId iacat-prod -Confirm
```

The script will:
1. Re-run all pre-flight checks.
2. Display the same purchase plan.
3. **Prompt you to type the project ID literally** before issuing the API call. This is the last safety guard.
4. Run `gcloud compute commitments create` against GCP.
5. Print the commitment status (should be `ACTIVE` immediately).

After this, you cannot cancel. The discount applies retroactively to the start-of-hour the commitment was created, so any VM running right now is already benefiting.

### Step 7 — Verify

```powershell
gcloud compute commitments list `
    --project=iacat-prod `
    --regions=asia-southeast1 `
    --format="table(name,status,plan,startTimestamp,endTimestamp)"
```

Status should be `ACTIVE`. Note the `endTimestamp` — that's your renewal date.

For a detailed view:

```powershell
gcloud compute commitments describe protectportal-n2-1yr `
    --region=asia-southeast1 `
    --project=iacat-prod
```

---

## Day-2 operations

### Monitor savings

1. Open billing reports: <https://console.cloud.google.com/billing/reports>
2. Filter by **SKU type** → `Commitment - <description>` to see what you're paying for the commitment.
3. Compare with non-commitment N2 line items.

Expected pattern after the first full billing cycle:
- A new line item for the commitment (flat hourly rate × hours in the month).
- N2 compute line items drop to (capacity above commitment) × on-demand rate.
- The two together should be lower than what your N2 line was pre-commitment.

### When VMs change

| Scenario | What to do |
| --- | --- |
| Add a new N2 VM in the same region, under the commitment ceiling | Nothing — the commitment auto-applies to it. |
| Scale prod up to `n2-standard-32` (32 vCPU + 128 GB) | Excess (12 vCPU + 56 GB) bills on-demand. Consider a SECOND commitment for that delta if it'll be stable. |
| Stop the DR VM permanently | Your 20 vCPU + 72 GB commitment now exceeds usage by 4 vCPU + 8 GB — you're paying for unused capacity. Either start something else N2-shaped in the region, or accept the loss until renewal. |
| Switch a VM to E2 family | The N2 commitment no longer covers it. Buy a separate E2 commitment if it'll be stable; the N2 commitment is wasted on the migrated VM. |
| Move a VM to a different region | The original-region commitment no longer applies. CUDs are region-scoped and non-transferable. |

### State this in Terraform (optional, recommended for IaC parity)

If you want the commitment to show up in `terraform state list` so future operators see it alongside the VMs, add this to a new file `commitments.tf`:

```hcl
resource "google_compute_region_commitment" "n2" {
  count       = var.enable_commitment ? 1 : 0
  name        = "protectportal-n2-1yr"
  region      = var.region
  plan        = "TWELVE_MONTH"          # or "THIRTY_SIX_MONTH"
  type        = "GENERAL_PURPOSE_N2"
  auto_renew  = false

  resources {
    type   = "VCPU"
    amount = "20"
  }
  resources {
    type   = "MEMORY"
    amount = "72"
  }
}
```

And add to `variables.tf`:

```hcl
variable "enable_commitment" {
  description = "Manage the production N2 CUD in Terraform. CUDs are non-cancellable; flip to true only after running the purchase script (or be ready for terraform apply to actually buy)."
  type        = bool
  default     = false
}
```

To **import** the commitment you already bought (so Terraform tracks it without re-creating):

```powershell
terraform import -var-file prod.tfvars `
    google_compute_region_commitment.n2[0] `
    projects/iacat-prod/regions/asia-southeast1/commitments/protectportal-n2-1yr
```

Then set `enable_commitment = true` in `prod.tfvars` and `terraform plan -var-file prod.tfvars` should show no changes.

> **Important:** `terraform destroy` on a `google_compute_region_commitment` does **not** cancel the commitment — Google refuses the delete call. To "remove" it from Terraform without affecting billing, use `terraform state rm google_compute_region_commitment.n2[0]`.

---

## End of term

Set a calendar reminder for **60 days before the `endTimestamp`** (`gcloud compute commitments describe ...` shows it). At that point:

1. Re-run the 30-day baseline analysis to see if usage has shifted.
2. Decide: renew at the same size, renew at a different size, or let it lapse and revert to on-demand.
3. If renewing: **the commitment does not auto-renew unless you set `--auto-renew` at purchase time** (the script does not enable auto-renew by default). Re-run the purchase script in good time.

If the term ends and you didn't renew, GCP automatically drops you back to on-demand pricing. There's no outage — the discount just stops applying.

---

## Troubleshooting

### Purchase script errors with `Billing not enabled`

```
ERROR: Billing is not enabled on 'iacat-prod'.
```

Link a billing account at <https://console.cloud.google.com/billing/linkedaccount?project=iacat-prod> and retry.

### `INVALID_ARGUMENT: Region "..." is not valid for the provided commitment type`

Not every machine family is available in every region. Check availability:

```powershell
gcloud compute machine-types list --filter="zone:(asia-southeast1) AND name~'n2-'" --format="value(name)" | Select-Object -First 5
```

If N2 isn't in `asia-southeast1`, you can't buy an N2 commitment there. Migrate to a region that supports it before committing.

### Bought the wrong size by mistake

You can't cancel, but you can buy a **second** commitment to top up — they stack additively. Or scale your VMs up (or in) to match. There is no way to shrink an existing commitment.

### Want to apply the discount across multiple projects

Set up [shared CUDs](https://cloud.google.com/billing/docs/how-to/cud-analysis-sharing) on the billing account. The discount then pools across every project on that billing account, not just the one you bought it in. Worth enabling even for a single-project setup — it future-proofs you.

```powershell
gcloud billing accounts get-iam-policy <BILLING_ACCOUNT_ID>
# (Sharing is configured per billing account in the Console, not via gcloud.)
```
