locals {
  # Labels applied to every labelable resource via provider default_labels.
  # Keys must be lowercase letters / digits / dashes / underscores.
  common_labels = {
    application = "protectportal"
    environment = var.environment
    cost_center = var.cost_center
    owner       = var.owner
    managed_by  = "terraform"
  }

  prod_name = "${var.name_prefix}-prod"
  dr_name   = "${var.name_prefix}-dr"

  # Per-VM effective disk image (used by boot_disk.initialize_params.image when
  # no machine image is set). Precedence: per-VM disk image > shared_image > ubuntu_image.
  prod_effective_disk_image = (
    var.prod_disk_image != "" ? var.prod_disk_image :
    var.shared_image != ""    ? var.shared_image    :
                                var.ubuntu_image
  )
  dr_effective_disk_image = (
    var.dr_disk_image != "" ? var.dr_disk_image :
    var.shared_image != ""  ? var.shared_image  :
                              var.ubuntu_image
  )

  # Each VM exists either as google_compute_instance (when no machine image is
  # set) or google_compute_instance_from_machine_image (when one IS set).
  # Use these abstractions everywhere else in the codebase so the rest of the
  # config doesn't care which path the user chose.
  prod_instance_self_link = (
    var.prod_machine_image != ""
    ? google_compute_instance_from_machine_image.prod[0].self_link
    : google_compute_instance.prod[0].self_link
  )
  prod_instance_id = (
    var.prod_machine_image != ""
    ? google_compute_instance_from_machine_image.prod[0].instance_id
    : google_compute_instance.prod[0].instance_id
  )
  dr_instance_self_link = (
    var.dr_machine_image != ""
    ? google_compute_instance_from_machine_image.dr[0].self_link
    : google_compute_instance.dr[0].self_link
  )
  dr_instance_id = (
    var.dr_machine_image != ""
    ? google_compute_instance_from_machine_image.dr[0].instance_id
    : google_compute_instance.dr[0].instance_id
  )

  prod_network_ip = (
    var.prod_machine_image != ""
    ? google_compute_instance_from_machine_image.prod[0].network_interface[0].network_ip
    : google_compute_instance.prod[0].network_interface[0].network_ip
  )
  dr_network_ip = (
    var.dr_machine_image != ""
    ? google_compute_instance_from_machine_image.dr[0].network_interface[0].network_ip
    : google_compute_instance.dr[0].network_interface[0].network_ip
  )

  # prod has a public IP via access_config on the disk-image path. For machine
  # image VMs the public IP exists only if the MI included one -- try() guards
  # the lookup so missing access_config doesn't crash terraform.
  prod_external_ip = try(
    var.prod_machine_image != ""
    ? google_compute_instance_from_machine_image.prod[0].network_interface[0].access_config[0].nat_ip
    : google_compute_instance.prod[0].network_interface[0].access_config[0].nat_ip,
    null
  )
}
