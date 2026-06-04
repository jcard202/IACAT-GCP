###############################################################################
# Firewall — deny-by-default. Each allow rule is scoped by network tags.
###############################################################################

# SSH only via Identity-Aware Proxy. No port 22 exposed to the public internet.
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = var.ssh_source_ranges
  target_tags   = ["ssh-iap"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Health checks + LB → backend traffic. Source ranges are Google's published LB ranges.
resource "google_compute_firewall" "allow_lb_health_checks" {
  name          = "${var.name_prefix}-allow-lb-hc"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["http-backend"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

# Replication / DR sync between prod and DR.
# SSH (22) covers scp/rsync of pg_dump output; 5432 covers a direct pg_dump pull
# from the DR side if you prefer that pattern over scp.
resource "google_compute_firewall" "allow_internal_prod_dr" {
  name        = "${var.name_prefix}-allow-internal"
  network     = google_compute_network.vpc.name
  direction   = "INGRESS"
  priority    = 1000
  source_tags = ["protectportal-prod", "protectportal-dr"]
  target_tags = ["protectportal-prod", "protectportal-dr"]

  allow {
    protocol = "tcp"
    ports    = ["22", "5432"]
  }

  allow {
    protocol = "icmp"
  }
}

# Catch-all explicit deny — logs unexpected ingress for audit.
resource "google_compute_firewall" "deny_all_ingress" {
  name               = "${var.name_prefix}-deny-all-ingress"
  network            = google_compute_network.vpc.name
  direction          = "INGRESS"
  priority           = 65534
  source_ranges      = ["0.0.0.0/0"]
  destination_ranges = []

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
