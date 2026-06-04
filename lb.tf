###############################################################################
# Google-managed SSL certificate (TLS 1.2 / 1.3 negotiated via SSL policy).
###############################################################################

resource "google_compute_managed_ssl_certificate" "portal" {
  count    = var.enable_https ? 1 : 0
  provider = google-beta
  name     = "${var.name_prefix}-managed-cert"

  managed {
    domains = [var.domain_name]
  }

  lifecycle {
    precondition {
      condition     = var.domain_name != ""
      error_message = "domain_name must be set when enable_https = true."
    }
  }
}

###############################################################################
# Modern SSL policy — TLS 1.2 minimum, MODERN cipher profile (TLS 1.3 enabled).
###############################################################################

resource "google_compute_ssl_policy" "modern" {
  count           = var.enable_https ? 1 : 0
  name            = "${var.name_prefix}-ssl-policy"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

###############################################################################
# Cloud Armor — WAF (OWASP rules) + adaptive DDoS protection.
###############################################################################

resource "google_compute_security_policy" "waf" {
  name        = "${var.name_prefix}-waf"
  description = "WAF and DDoS protection for ProtectPortal"
  type        = "CLOUD_ARMOR"

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }

  # OWASP CRS preconfigured rules
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection"
  }

  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block XSS"
  }

  rule {
    action   = "deny(403)"
    priority = 1002
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-v33-stable')"
      }
    }
    description = "Block local file inclusion"
  }

  rule {
    action   = "deny(403)"
    priority = 1003
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rfi-v33-stable')"
      }
    }
    description = "Block remote file inclusion"
  }

  rule {
    action   = "deny(403)"
    priority = 1004
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rce-v33-stable')"
      }
    }
    description = "Block remote code execution"
  }

  rule {
    action   = "deny(403)"
    priority = 1005
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('scannerdetection-v33-stable')"
      }
    }
    description = "Block known scanners"
  }

  # Per-IP rate limiting — DDoS mitigation belt-and-suspenders.
  rule {
    action   = "rate_based_ban"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "Rate limit: 600 req/min per source IP"
  }

  # Default allow — must remain last (priority 2147483647 is the implicit default).
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}

###############################################################################
# Health check, backend service, URL map, HTTPS proxy, forwarding rule.
###############################################################################

resource "google_compute_health_check" "http" {
  name                = "${var.name_prefix}-http-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/"
  }

  log_config {
    enable = true
  }
}

resource "google_compute_backend_service" "portal" {
  name                  = "${var.name_prefix}-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  enable_cdn            = false

  backend {
    group           = google_compute_instance_group.prod.id
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }

  health_checks   = [google_compute_health_check.http.id]
  security_policy = google_compute_security_policy.waf.id

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  # HSTS + other security headers at the LB layer (in addition to nginx).
  custom_response_headers = [
    "Strict-Transport-Security: max-age=63072000; includeSubDomains; preload",
    "X-Content-Type-Options: nosniff",
    "X-Frame-Options: DENY",
    "Referrer-Policy: strict-origin-when-cross-origin",
  ]
}

resource "google_compute_url_map" "portal" {
  name            = "${var.name_prefix}-urlmap"
  default_service = google_compute_backend_service.portal.id
}

resource "google_compute_target_https_proxy" "portal" {
  count            = var.enable_https ? 1 : 0
  name             = "${var.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.portal.id
  ssl_certificates = [google_compute_managed_ssl_certificate.portal[0].id]
  ssl_policy       = google_compute_ssl_policy.modern[0].id
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.enable_https ? 1 : 0
  name                  = "${var.name_prefix}-https-fr"
  ip_address            = google_compute_global_address.lb_ip.address
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.portal[0].id

  labels = local.common_labels
}

###############################################################################
# Port 80 entry point.
#
# When HTTPS is enabled, the HTTP proxy points at a url_map that 301-redirects
# every request to HTTPS. When HTTPS is disabled (test mode), the HTTP proxy
# routes directly to the backend so the deploy is reachable without DNS / SSL.
###############################################################################

resource "google_compute_url_map" "http_redirect" {
  count = var.enable_https ? 1 : 0
  name  = "${var.name_prefix}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http" {
  name    = "${var.name_prefix}-http-proxy"
  url_map = var.enable_https ? google_compute_url_map.http_redirect[0].id : google_compute_url_map.portal.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name_prefix}-http-fr"
  ip_address            = google_compute_global_address.lb_ip.address
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.http.id

  labels = local.common_labels
}

###############################################################################
# Optional Cloud DNS A record.
###############################################################################

resource "google_dns_record_set" "portal_a" {
  count        = var.create_dns_record ? 1 : 0
  managed_zone = var.dns_managed_zone
  name         = "${var.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb_ip.address]
}
