###############################################################################
# Notification channel (email).
###############################################################################

resource "google_monitoring_notification_channel" "email" {
  display_name = "${var.name_prefix} ops email"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

###############################################################################
# Uptime check against the portal domain.
###############################################################################

resource "google_monitoring_uptime_check_config" "portal_https" {
  count        = var.enable_https && var.domain_name != "" ? 1 : 0
  display_name = "${var.name_prefix}-https-uptime"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain_name
    }
  }
}

###############################################################################
# Alert policies — CPU, memory, disk, uptime failures.
###############################################################################

resource "google_monitoring_alert_policy" "prod_cpu_high" {
  display_name = "${local.prod_name} CPU > 85%"
  combiner     = "OR"

  conditions {
    display_name = "CPU utilization above 85%"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\" AND resource.labels.instance_id = \"${local.prod_instance_id}\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "prod_memory_high" {
  display_name = "${local.prod_name} memory > 90%"
  combiner     = "OR"

  conditions {
    display_name = "Memory utilization above 90%"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"agent.googleapis.com/memory/percent_used\" AND metric.labels.state = \"used\" AND resource.labels.instance_id = \"${local.prod_instance_id}\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 90
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

resource "google_monitoring_alert_policy" "prod_disk_high" {
  display_name = "${local.prod_name} disk > 85%"
  combiner     = "OR"

  conditions {
    display_name = "Disk utilization above 85%"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.labels.state = \"used\" AND resource.labels.instance_id = \"${local.prod_instance_id}\""
      duration        = "600s"
      comparison      = "COMPARISON_GT"
      threshold_value = 85
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

resource "google_monitoring_alert_policy" "uptime_failed" {
  count        = var.enable_https && var.domain_name != "" ? 1 : 0
  display_name = "${var.name_prefix} HTTPS uptime failed"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.portal_https[0].uptime_check_id}\""
      duration        = "120s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

###############################################################################
# Log-based metric — failed SSH login attempts.
###############################################################################

resource "google_logging_metric" "failed_ssh" {
  name        = "${var.name_prefix}/failed_ssh_attempts"
  description = "Failed SSH authentication attempts."
  filter      = "resource.type=\"gce_instance\" AND logName=~\"syslog|auth\" AND textPayload=~\"Failed password|Invalid user\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "ssh_brute_force" {
  display_name = "${var.name_prefix} suspected SSH brute force"
  combiner     = "OR"

  conditions {
    display_name = "Failed SSH attempts > 20 / 5m"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.failed_ssh.name}\" AND resource.type = \"gce_instance\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 20
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

###############################################################################
# Audit log sink — exported to a dedicated GCS bucket for retention.
###############################################################################

resource "random_id" "audit_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "audit_logs" {
  name                        = "${var.project_id}-${var.name_prefix}-audit-${random_id.audit_suffix.hex}"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 400
    }
    action {
      type = "Delete"
    }
  }

  retention_policy {
    retention_period = 86400 # 1 day minimum WORM lock; tune up if compliance requires
  }
}

resource "google_logging_project_sink" "audit" {
  name        = "${var.name_prefix}-audit-sink"
  description = "All admin/data-access audit logs → GCS"
  destination = "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com" OR
    protoPayload.serviceName="compute.googleapis.com" OR
    protoPayload.serviceName="iam.googleapis.com" OR
    protoPayload.serviceName="cloudkms.googleapis.com"
  EOT

  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "audit_writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit.writer_identity
}

###############################################################################
# Custom dashboard — comprehensive view of the stack.
#
# Sections, top to bottom:
#   - Production VM:  CPU, load, memory, network, BOOT disk %, DATA disk %,
#                     BOOT disk IOPS, DATA disk IOPS
#   - DR VM:          CPU, memory, BOOT disk %, DATA disk %,
#                     BOOT disk IOPS, DATA disk IOPS, network
#   - Load balancer:  request rate, latency percentiles, response codes
#   - Edge security:  WAF blocked requests, failed SSH attempts
#
# Disk filter conventions (matters when adding metrics):
#   - Ops Agent (% used):  metric.labels.device =~ "sda.*"  → boot
#                          metric.labels.device =~ "sdb.*"  → data (attached)
#   - Compute API (IOPS):  metric.labels.device_name != "protectportal-*-data"
#                            → boot (anything other than our data disk's device_name)
#                          metric.labels.device_name = "protectportal-prod-data"
#                          metric.labels.device_name = "protectportal-dr-data"
###############################################################################

locals {
  # Per-instance filter helpers keep the JSON below readable.
  prod_filter = "resource.labels.instance_id=\"${local.prod_instance_id}\""
  dr_filter   = "resource.labels.instance_id=\"${local.dr_instance_id}\""
}

resource "google_monitoring_dashboard" "portal" {
  dashboard_json = jsonencode({
    displayName = "${var.name_prefix} Overview"
    mosaicLayout = {
      columns = 12
      tiles = [
        # ===== Section banner: Production VM =====
        { xPos = 0, yPos = 0, width = 12, height = 1,
          widget = { title = "", text = {
            content = "## Production VM (${local.prod_name})"
            format  = "MARKDOWN"
          }}
        },

        # ----- Row: CPU + Load average -----
        { xPos = 0, yPos = 1, width = 6, height = 4,
          widget = { title = "Prod • CPU utilization", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND ${local.prod_filter}"
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 1, width = 6, height = 4,
          widget = { title = "Prod • Load average (1m / 5m / 15m)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/cpu/load_1m\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              }}
              plotType = "LINE", legendTemplate = "1m" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/cpu/load_5m\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              }}
              plotType = "LINE", legendTemplate = "5m" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/cpu/load_15m\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
              }}
              plotType = "LINE", legendTemplate = "15m" }
          ]}}
        },

        # ----- Row: Memory + Network -----
        { xPos = 0, yPos = 5, width = 6, height = 4,
          widget = { title = "Prod • Memory used %", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/memory/percent_used\" AND metric.labels.state=\"used\" AND ${local.prod_filter}"
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 5, width = 6, height = 4,
          widget = { title = "Prod • Network throughput (in / out)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/network/received_bytes_count\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE" }
              }}
              plotType = "LINE", legendTemplate = "in" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/network/sent_bytes_count\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE" }
              }}
              plotType = "LINE", legendTemplate = "out" }
          ]}}
        },

        # ----- Row: Boot disk % + Data disk % -----
        { xPos = 0, yPos = 9, width = 6, height = 4,
          widget = { title = "Prod • Boot disk used %", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/disk/percent_used\" AND metric.labels.state=\"used\" AND metric.labels.device=monitoring.regex.full_match(\"sda.*\") AND ${local.prod_filter}"
              aggregation = {
                alignmentPeriod    = "300s"
                perSeriesAligner   = "ALIGN_MEAN"
                crossSeriesReducer = "REDUCE_MAX"
                groupByFields      = ["metric.label.device"]
              }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 9, width = 6, height = 4,
          widget = { title = "Prod • Data disk used % (/data)", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/disk/percent_used\" AND metric.labels.state=\"used\" AND metric.labels.device=monitoring.regex.full_match(\"sdb.*\") AND ${local.prod_filter}"
              aggregation = {
                alignmentPeriod    = "300s"
                perSeriesAligner   = "ALIGN_MEAN"
                crossSeriesReducer = "REDUCE_MAX"
                groupByFields      = ["metric.label.device"]
              }
            }}
            plotType = "LINE"
          }]}}
        },

        # ----- Row: Boot disk IOPS + Data disk IOPS -----
        { xPos = 0, yPos = 13, width = 6, height = 4,
          widget = { title = "Prod • Boot disk IOPS (read / write)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/read_ops_count\" AND metric.labels.device_name!=\"protectportal-prod-data\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "read" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/write_ops_count\" AND metric.labels.device_name!=\"protectportal-prod-data\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "write" }
          ]}}
        },
        { xPos = 6, yPos = 13, width = 6, height = 4,
          widget = { title = "Prod • Data disk IOPS (read / write)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/read_ops_count\" AND metric.labels.device_name=\"protectportal-prod-data\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "read" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/write_ops_count\" AND metric.labels.device_name=\"protectportal-prod-data\" AND ${local.prod_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "write" }
          ]}}
        },

        # ===== Section banner: DR VM =====
        { xPos = 0, yPos = 17, width = 12, height = 1,
          widget = { title = "", text = {
            content = "## DR VM (${local.dr_name})"
            format  = "MARKDOWN"
          }}
        },

        { xPos = 0, yPos = 18, width = 6, height = 4,
          widget = { title = "DR • CPU utilization", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND ${local.dr_filter}"
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 18, width = 6, height = 4,
          widget = { title = "DR • Memory used %", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/memory/percent_used\" AND metric.labels.state=\"used\" AND ${local.dr_filter}"
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
            }}
            plotType = "LINE"
          }]}}
        },

        # ----- Row: Boot disk % + Data disk % -----
        { xPos = 0, yPos = 22, width = 6, height = 4,
          widget = { title = "DR • Boot disk used %", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/disk/percent_used\" AND metric.labels.state=\"used\" AND metric.labels.device=monitoring.regex.full_match(\"sda.*\") AND ${local.dr_filter}"
              aggregation = {
                alignmentPeriod    = "300s"
                perSeriesAligner   = "ALIGN_MEAN"
                crossSeriesReducer = "REDUCE_MAX"
                groupByFields      = ["metric.label.device"]
              }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 22, width = 6, height = 4,
          widget = { title = "DR • Data disk used % (/backups)", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/disk/percent_used\" AND metric.labels.state=\"used\" AND metric.labels.device=monitoring.regex.full_match(\"sdb.*\") AND ${local.dr_filter}"
              aggregation = {
                alignmentPeriod    = "300s"
                perSeriesAligner   = "ALIGN_MEAN"
                crossSeriesReducer = "REDUCE_MAX"
                groupByFields      = ["metric.label.device"]
              }
            }}
            plotType = "LINE"
          }]}}
        },

        # ----- Row: Boot disk IOPS + Data disk IOPS -----
        { xPos = 0, yPos = 26, width = 6, height = 4,
          widget = { title = "DR • Boot disk IOPS (read / write)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/read_ops_count\" AND metric.labels.device_name!=\"protectportal-dr-data\" AND ${local.dr_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "read" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/write_ops_count\" AND metric.labels.device_name!=\"protectportal-dr-data\" AND ${local.dr_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "write" }
          ]}}
        },
        { xPos = 6, yPos = 26, width = 6, height = 4,
          widget = { title = "DR • Data disk IOPS (read / write)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/read_ops_count\" AND metric.labels.device_name=\"protectportal-dr-data\" AND ${local.dr_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "read" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/disk/write_ops_count\" AND metric.labels.device_name=\"protectportal-dr-data\" AND ${local.dr_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
              }}
              plotType = "LINE", legendTemplate = "write" }
          ]}}
        },

        # ----- Row: Network throughput (DR) -----
        { xPos = 0, yPos = 30, width = 12, height = 4,
          widget = { title = "DR • Network throughput (in / out)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/network/received_bytes_count\" AND ${local.dr_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE" }
              }}
              plotType = "LINE", legendTemplate = "in" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/network/sent_bytes_count\" AND ${local.dr_filter}"
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE" }
              }}
              plotType = "LINE", legendTemplate = "out" }
          ]}}
        },

        # ===== Section banner: Load balancer =====
        { xPos = 0, yPos = 34, width = 12, height = 1,
          widget = { title = "", text = {
            content = "## Load Balancer"
            format  = "MARKDOWN"
          }}
        },

        { xPos = 0, yPos = 35, width = 6, height = 4,
          widget = { title = "LB • Request rate (req/sec)", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"https_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/request_count\""
              aggregation = {
                alignmentPeriod    = "60s"
                perSeriesAligner   = "ALIGN_RATE"
                crossSeriesReducer = "REDUCE_SUM"
              }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 35, width = 6, height = 4,
          widget = { title = "LB • Total latency (p50 / p95 / p99)", xyChart = { dataSets = [
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"https_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/total_latencies\""
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_50", crossSeriesReducer = "REDUCE_MEAN" }
              }}
              plotType = "LINE", legendTemplate = "p50" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"https_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/total_latencies\""
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_95", crossSeriesReducer = "REDUCE_MEAN" }
              }}
              plotType = "LINE", legendTemplate = "p95" },
            { timeSeriesQuery = { timeSeriesFilter = {
                filter      = "resource.type=\"https_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/total_latencies\""
                aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_99", crossSeriesReducer = "REDUCE_MEAN" }
              }}
              plotType = "LINE", legendTemplate = "p99" }
          ]}}
        },

        { xPos = 0, yPos = 39, width = 12, height = 4,
          widget = { title = "LB • Request count by response-code class", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"https_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/request_count\""
              aggregation = {
                alignmentPeriod    = "60s"
                perSeriesAligner   = "ALIGN_RATE"
                crossSeriesReducer = "REDUCE_SUM"
                groupByFields      = ["metric.label.response_code_class"]
              }
            }}
            plotType = "STACKED_AREA"
          }]}}
        },

        # ===== Section banner: Edge security =====
        { xPos = 0, yPos = 43, width = 12, height = 1,
          widget = { title = "", text = {
            content = "## Edge Security"
            format  = "MARKDOWN"
          }}
        },

        { xPos = 0, yPos = 44, width = 6, height = 4,
          widget = { title = "WAF • Requests denied (HTTP 4xx via Cloud Armor)", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "resource.type=\"https_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND metric.labels.response_code_class=400"
              aggregation = {
                alignmentPeriod    = "60s"
                perSeriesAligner   = "ALIGN_RATE"
                crossSeriesReducer = "REDUCE_SUM"
              }
            }}
            plotType = "LINE"
          }]}}
        },
        { xPos = 6, yPos = 44, width = 6, height = 4,
          widget = { title = "Auth • Failed SSH attempts (log-based)", xyChart = { dataSets = [{
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.failed_ssh.name}\" AND resource.type=\"gce_instance\""
              aggregation = {
                alignmentPeriod    = "300s"
                perSeriesAligner   = "ALIGN_SUM"
                crossSeriesReducer = "REDUCE_SUM"
                groupByFields      = ["resource.label.instance_id"]
              }
            }}
            plotType = "STACKED_BAR"
          }]}}
        },
      ]
    }
  })
}
