# Operations Guide

Day-2 tasks: SSH, backups, DR drill, scaling, log queries, and recovery from common failure modes.

---

## SSH access

SSH is **only** allowed via Identity-Aware Proxy. Port 22 is closed to the public internet.

```bash
# Convenience — read the exact command from Terraform output
terraform output -raw ssh_via_iap_prod | bash
terraform output -raw ssh_via_iap_dr   | bash

# Or run it directly
gcloud compute ssh protectportal-prod \
  --zone=asia-southeast1-a \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID

gcloud compute ssh protectportal-dr \
  --zone=asia-southeast1-b \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID
```

### Granting another engineer SSH access

OS Login is enforced. To grant access, give them both:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:alice@example.com" \
  --role="roles/iap.tunnelResourceAccessor"

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:alice@example.com" \
  --role="roles/compute.osLogin"
```

For sudo, replace `osLogin` with `osAdminLogin`.

---

## Backups

### What is backed up

| Disk | Snapshot schedule | Retention |
| --- | --- | --- |
| `protectportal-prod-data` (2 TB) | daily 01:00 SGT | 30 days |
| `protectportal-dr-data` (500 GB) | daily 01:00 SGT | 30 days |
| Boot disks (50 GB each) | *not snapshotted by default* — they are stateless |

### List recent snapshots

```bash
gcloud compute snapshots list --filter="sourceDisk:protectportal-prod-data" \
  --format="table(name,creationTimestamp,diskSizeGb,status)"
```

### Restore from a snapshot

```bash
# 1. Create a new disk from the snapshot
gcloud compute disks create protectportal-prod-data-restore \
  --source-snapshot=<snapshot-name> \
  --zone=asia-southeast1-a \
  --type=pd-ssd

# 2. Stop the prod VM
gcloud compute instances stop protectportal-prod --zone=asia-southeast1-a

# 3. Detach the old data disk, attach the restored one
gcloud compute instances detach-disk protectportal-prod \
  --disk=protectportal-prod-data --zone=asia-southeast1-a

gcloud compute instances attach-disk protectportal-prod \
  --disk=protectportal-prod-data-restore \
  --device-name=protectportal-prod-data \
  --zone=asia-southeast1-a

# 4. Start the VM. The startup script mounts the disk at /data automatically.
gcloud compute instances start protectportal-prod --zone=asia-southeast1-a
```

Update Terraform afterwards (rename in state or import the new disk) so subsequent `terraform apply` doesn't try to revert the change.

---

## Daily SQL dump → DR validation workflow

This is the recommended cron job for the DR VM. Adapt for your actual database.

```bash
# On the PROD VM — push a dump to the DR VM each night
# /etc/cron.daily/protectportal-dump
#!/bin/bash
set -euo pipefail
TS=$(date +%Y%m%d)
DUMP=/data/dumps/portal-${TS}.sql.gz

mkdir -p /data/dumps
pg_dump -U postgres protectportal | gzip > "$DUMP"

# Copy to DR via internal IP using IAP-less, in-VPC SSH
DR_IP=$(gcloud compute instances describe protectportal-dr \
  --zone=asia-southeast1-b --format='value(networkInterfaces[0].networkIP)')
scp -o StrictHostKeyChecking=accept-new "$DUMP" "$DR_IP:/backups/dumps/"

# Cleanup local dumps older than 7 days (snapshots cover longer-term)
find /data/dumps -name 'portal-*.sql.gz' -mtime +7 -delete
```

```bash
# On the DR VM — restore each morning to validate the dump
# /etc/cron.daily/protectportal-restore-test
#!/bin/bash
set -euo pipefail
LATEST=$(ls -1t /backups/dumps/portal-*.sql.gz | head -1)
DB=portal_restore_test

dropdb --if-exists "$DB"
createdb "$DB"
gunzip -c "$LATEST" | psql "$DB"

# Smoke check — fails the cron if no rows
psql "$DB" -c "SELECT count(*) FROM users;" | grep -qv '\s0$' \
  || { logger -t portal-restore "RESTORE VALIDATION FAILED"; exit 1; }
```

Alerts on failures go through Cloud Logging — the `logger` call produces a syslog entry that you can attach a log-based alert to.

---

## DR drill (quarterly)

Document the run-time and any deviations after each drill.

1. **Pick the most recent snapshot of `protectportal-prod-data`.**
2. **Create a temporary disk** from that snapshot in `asia-southeast1-b`.
3. **Spin up a temporary VM** in the DR subnet using that disk.
4. **Boot the application stack** and run smoke tests.
5. **Record RTO** (start of restore → app responding).
6. **Tear down** the temporary VM and disk.

Target RTO: **<2 hours** from snapshot to app responding.
Target RPO: **<24 hours** (daily snapshot cadence).

If those targets aren't met, file a ticket to upgrade to Cloud SQL HA or move to hourly snapshots.

---

## Scaling

### Vertical (more CPU/RAM on prod)

```hcl
# variables.tf — bump default, or override in terraform.tfvars
prod_machine_type = "n2-standard-32"   # 32 vCPU / 128 GB
```

```bash
terraform apply
```

The VM is stopped, resized, and restarted (`allow_stopping_for_update = true`). Expect ~2 minutes of downtime. Run during a maintenance window.

### Disk capacity

Persistent disks can be grown online — no downtime.

```hcl
prod_data_disk_size_gb = 4096   # 4 TB
```

```bash
terraform apply
```

Then on the VM, extend the filesystem:

```bash
sudo resize2fs /dev/disk/by-id/google-protectportal-prod-data
df -h /data
```

Disks cannot be **shrunk** — once grown, you'd have to snapshot, recreate from snapshot at smaller size, and swap. Avoid over-provisioning.

### Horizontal

Out of scope for this stack. To go horizontal:
1. Move state (DB, sessions, uploads) off the VM into Cloud SQL + Cloud Storage.
2. Replace the single VM in the instance group with a regional Managed Instance Group.
3. Add an autoscaler driven by request rate or CPU.

---

## Log queries

Cloud Logging UI → **Logs Explorer**, or via CLI:

```bash
# Last 1 hour of prod VM logs
gcloud logging read \
  'resource.type="gce_instance" AND resource.labels.instance_id="'$(gcloud compute instances describe protectportal-prod --zone=asia-southeast1-a --format='value(id)')'"' \
  --limit=50 --freshness=1h

# Cloud Armor blocks in the last 24h
gcloud logging read \
  'resource.type="http_load_balancer" AND jsonPayload.enforcedSecurityPolicy.outcome="DENY"' \
  --limit=50 --freshness=1d \
  --format="value(timestamp,jsonPayload.remoteIp,jsonPayload.enforcedSecurityPolicy.name)"

# Failed SSH attempts (the same data the log-based metric reads)
gcloud logging read \
  'resource.type="gce_instance" AND textPayload=~"Failed password|Invalid user"' \
  --limit=20 --freshness=1d
```

---

## Cost optimization

| Lever | Saving | How |
| --- | --- | --- |
| 1-year CUD on prod VM | ~30% | `Compute Engine → Committed-use discounts → Purchase` |
| 3-year CUD on prod VM | ~50% | same |
| `pd-balanced` for data disk | ~40% off disk | `prod_data_disk_type = "pd-balanced"` |
| Stop DR VM when not in active use | ~95% of DR compute | snapshots still run regardless of VM state |
| Reduce VPC Flow Logs sampling | ~10% of logging | edit `network.tf`, drop `flow_sampling` to 0.1 |
| Audit log lifecycle | depends on volume | tighten the 400-day rule if your retention SLA is shorter |

CUDs and rightsizing recommendations show up in **Billing → Reports → Cost optimization recommendations** after ~30 days of usage data.

---

## Common issues

### "Managed SSL certificate stuck in PROVISIONING"

Cause: DNS doesn't resolve to the LB IP, or it resolves to the wrong IP.

```bash
dig +short portal.example.com         # must equal terraform output load_balancer_ip
gcloud compute ssl-certificates describe protectportal-managed-cert --global
```

Fix the DNS record. The cert checks every few minutes; expect another 15–60 minutes after DNS is correct.

### "Backend service health check failing"

Cause: nginx didn't come up, or it's listening on the wrong port.

```bash
# SSH to prod
sudo systemctl status nginx
sudo tail -100 /var/log/nginx/error.log
sudo ss -tlnp | grep ':80'
```

The LB health check expects HTTP 200 on port 80 path `/`. The default nginx welcome page satisfies that — replace with your app, but keep something responding on `/` or change the health check path.

### "VPC firewall change has no effect"

GCP firewall rules apply by **network tag**, not instance name. Verify the instance has the expected tag:

```bash
gcloud compute instances describe protectportal-prod \
  --zone=asia-southeast1-a --format="value(tags.items)"
```

If you change tags, the new rules take effect immediately — no instance restart needed.

### "VM auto-restarted itself"

That's correct behaviour — `automatic_restart = true` is the spec. Check `serial-port-output` in the Console for a kernel panic or OOM, or look at the Ops Agent `agent.googleapis.com/memory/percent_used` metric leading up to the restart timestamp.

### "I deleted the data disk by accident"

You can't, while `prevent_destroy = true` is set in `compute.tf`. If you removed that line and then ran `terraform destroy`, restore from the most recent daily snapshot (see [Restore from a snapshot](#restore-from-a-snapshot)).

---

## Tearing down (intentional)

```bash
# 1. Remove deletion protection from the VMs
sed -i 's/deletion_protection = true/deletion_protection = false/' compute.tf
terraform apply

# 2. Remove the prevent_destroy from disks
sed -i '/prevent_destroy = true/d' compute.tf
terraform apply

# 3. Destroy
terraform destroy
```

The audit-log GCS bucket has a `retention_policy` — `terraform destroy` will fail to delete it if any object is still within the retention window. Wait for the 1-day window to elapse, or remove the retention policy first.
