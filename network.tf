###############################################################################
# Custom VPC — no default network, no auto-mode subnets.
###############################################################################

resource "google_compute_network" "vpc" {
  name                            = "${var.name_prefix}-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "prod" {
  name                     = "${var.name_prefix}-prod-subnet"
  ip_cidr_range            = var.vpc_cidr_prod
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "dr" {
  name                     = "${var.name_prefix}-dr-subnet"
  ip_cidr_range            = var.vpc_cidr_dr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

###############################################################################
# Cloud NAT — egress for VMs without public IPs (DR is private).
###############################################################################

resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

###############################################################################
# Reserved global IP for the HTTPS load balancer.
###############################################################################

resource "google_compute_global_address" "lb_ip" {
  name         = "${var.name_prefix}-lb-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}
