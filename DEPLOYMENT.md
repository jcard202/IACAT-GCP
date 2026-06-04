# Deployment Guide

End-to-end first-time deployment. Allow ~30 minutes for `terraform apply` plus another 15–60 minutes for the Google-managed SSL certificate to validate.

> **Before you start:** work through **[PREREQUISITES.md](PREREQUISITES.md)** — it covers installing the tooling, creating/picking the GCP project, enabling billing, IAM roles, and both `gcloud auth login` and `gcloud auth application-default login`. This guide assumes all of that is done.

---

## 0. Sanity check the prerequisites

```bash
# Terraform (>=1.6)
terraform version

# gcloud CLI
gcloud --version
```

---

## 1. Authenticate to GCP

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

`application-default login` is what Terraform reads. Don't skip it.

---

## 2. Enable required APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  iap.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com
```

Only if you set `create_dns_record = true`, also enable:

```bash
gcloud services enable dns.googleapis.com
```

API enablement is eventually consistent — wait ~30 seconds before running `terraform apply` if you just enabled them.

---

## 3. Create a Terraform state bucket

State should live in GCS, not locally. Pick a globally-unique name.

```bash
PROJECT_ID=$(gcloud config get-value project)
gcloud storage buckets create gs://${PROJECT_ID}-tfstate \
  --location=asia-southeast1 \
  --uniform-bucket-level-access \
  --public-access-prevention

# Versioning protects against accidental state loss
gcloud storage buckets update gs://${PROJECT_ID}-tfstate --versioning
```

---

## 4. Configure inputs

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
project_id  = "your-gcp-project-id"
domain_name = "portal.example.com"
alert_email = "ops@example.com"

# Optional — uncomment to manage DNS in Cloud DNS:
# create_dns_record = true
# dns_managed_zone  = "example-com"
```

**Required:**
- `project_id` — the GCP project you authenticated against in step 1.
- `domain_name` — must be a real DNS name you control. Google validates ownership by HTTP-01 / TLS-ALPN, and the cert will stay in `PROVISIONING` forever if DNS doesn't resolve to the LB IP.
- `alert_email` — receives Cloud Monitoring alerts.

---

## 5. Initialize Terraform

```bash
terraform init \
  -backend-config="bucket=${PROJECT_ID}-tfstate" \
  -backend-config="prefix=protectportal/prod"
```

The `prefix` lets you reuse the same bucket for other environments (`protectportal/staging`, `protectportal/qa`).

---

## 6. Plan

```bash
terraform plan -var-file prod.tfvars -out tfplan
```

Expect ~40 resources to be created. Skim the plan for:
- The two `google_compute_instance` resources with the correct machine types.
- The two `google_compute_disk` resources with the correct sizes.
- The Cloud Armor security policy with all OWASP rules.
- The `google_compute_managed_ssl_certificate` referencing your domain.

---

## 7. Apply

```bash
terraform apply tfplan
```

VM creation typically takes 2–3 minutes per instance; the load balancer and managed cert push total runtime to ~10 minutes.

If apply errors with `quotaExceeded` for `N2_CPUS`, request a quota increase at `IAM & Admin → Quotas` (you need at least 20 N2 vCPUs in `asia-southeast1`).

---

## 8. Point DNS at the load balancer

```bash
terraform output load_balancer_ip
```

Create an A record at your DNS provider:

```
portal.example.com.   A   <load_balancer_ip>   TTL 300
```

If you set `create_dns_record = true` and `dns_managed_zone = "..."`, Terraform already created the A record — skip this step.

---

## 9. Wait for the managed SSL certificate

The cert provisions automatically once DNS resolves to the LB IP. Check status:

```bash
gcloud compute ssl-certificates describe protectportal-managed-cert --global \
  --format="value(managed.status,managed.domainStatus)"
```

Expect this progression over 15–60 minutes:
- `PROVISIONING` / `PROVISIONING`
- `PROVISIONING` / `ACTIVE` (DNS validated)
- `ACTIVE` / `ACTIVE` (ready to serve)

While the cert is provisioning, clients will see SSL errors — that's normal. Don't recreate the certificate; it just needs time and reachable DNS.

---

## 10. Post-deploy verification

```bash
# 10.1 SSH to the prod VM via IAP (no public SSH exposure required)
terraform output -raw ssh_via_iap_prod | bash

# Inside the prod VM:
df -h | grep /data            # 2 TB data disk mounted at /data
systemctl status nginx        # nginx running
systemctl status google-cloud-ops-agent
exit

# 10.2 SSH to the DR VM
terraform output -raw ssh_via_iap_dr | bash

# Inside the DR VM:
df -h | grep /backups         # 500 GB data disk mounted at /backups
psql --version                 # PostgreSQL 16 client installed
sudo -u postgres psql -c '\l'  # cluster listening, default DBs present
exit

# 10.3 Verify the load balancer is healthy
gcloud compute backend-services get-health protectportal-backend --global

# 10.4 Verify TLS once the cert is ACTIVE
curl -vI https://portal.example.com 2>&1 | grep -E "HTTP|strict-transport"

# 10.5 Verify Cloud Armor is attached
gcloud compute backend-services describe protectportal-backend --global \
  --format="value(securityPolicy)"
```

If `curl` shows `HTTP/2 200` and the `strict-transport-security` header, you're done.

---

## 11. (Optional) Remove the prod VM's direct public IP

Once the LB is serving traffic and you no longer need direct admin access:

1. Edit `compute.tf`, remove the `access_config { ... }` block from the prod `network_interface`.
2. `terraform apply`.
3. All external traffic now flows through Cloud Armor. SSH remains available via IAP.

---

## 12. Rollback

```bash
terraform destroy
```

Two safety nets will block destroy:
- `prevent_destroy = true` on both data disks — remove that line first if you really want to delete the data.
- `deletion_protection = true` on both VMs — `terraform apply` after removing it to release the protection, then destroy.

Daily snapshots in the snapshot policy survive `terraform destroy` and can rehydrate disks from up to 30 days back.
