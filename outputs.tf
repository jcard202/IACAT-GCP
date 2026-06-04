output "prod_instance_name" {
  description = "Production VM name."
  value       = local.prod_name
}

output "prod_internal_ip" {
  description = "Production VM internal IP."
  value       = local.prod_network_ip
}

output "prod_external_ip" {
  description = "Production VM external IP (direct, bypasses LB)."
  value       = local.prod_external_ip
}

output "dr_instance_name" {
  description = "DR VM name."
  value       = local.dr_name
}

output "dr_internal_ip" {
  description = "DR VM internal IP (no public IP)."
  value       = local.dr_network_ip
}

output "load_balancer_ip" {
  description = "Global anycast IP for the HTTPS load balancer. Point your DNS A record here."
  value       = google_compute_global_address.lb_ip.address
}

output "domain_name" {
  description = "Domain attached to the managed SSL certificate."
  value       = var.domain_name
}

output "audit_log_bucket" {
  description = "GCS bucket where audit logs are exported."
  value       = google_storage_bucket.audit_logs.name
}

output "ssh_via_iap_prod" {
  description = "Command to SSH into the production VM through IAP."
  value       = "gcloud compute ssh ${local.prod_name} --zone=${var.prod_zone} --tunnel-through-iap --project=${var.project_id}"
}

output "ssh_via_iap_dr" {
  description = "Command to SSH into the DR VM through IAP."
  value       = "gcloud compute ssh ${local.dr_name} --zone=${var.dr_zone} --tunnel-through-iap --project=${var.project_id}"
}
