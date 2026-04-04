# GCP Infrastructure — data-driven from terraform.json
# All values live in terraform.json; this file is a pure template.

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
  # Index instances by name for resource addressing
  instances_with_static_ip = { for i in local.config.instances : i.name => i if i.static_ip_name != null }
  instances_with_gpu       = { for i in local.config.instances : i.name => i if i.gpu != null }
}

# =============================================================================
# Provider
# =============================================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = local.config.provider.project_id
  region  = local.config.provider.region
  zone    = local.config.provider.zone
}

provider "google-beta" {
  project = local.config.provider.project_id
  region  = local.config.provider.region
  zone    = local.config.provider.zone
}

variable "ssh_public_key" {
  description = "SSH public key for diego user"
  type        = string
  # Set via: TF_VAR_ssh_public_key=$(cat ~/git/vault/A0_keys/ssh/google_compute_engine.pub)
  # Or via build.sh which reads from vault automatically
}

# =============================================================================
# VPC Network
# =============================================================================

resource "google_compute_network" "main" {
  name                    = local.config.network.name
  description             = local.config.network.description
  auto_create_subnetworks = local.config.network.auto_create_subnetworks

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# Firewall Rules — all from terraform.json
# NOTE: default-allow-icmp, default-allow-internal, default-allow-rdp,
#       default-allow-ssh are GCP auto-created defaults — NOT managed here.
# =============================================================================

resource "google_compute_firewall" "rules" {
  for_each = { for r in local.config.firewall_rules : r.name => r }

  name    = each.value.name
  network = google_compute_network.main.name

  allow {
    protocol = each.value.protocol
    ports    = each.value.ports
  }

  source_ranges = [each.value.source]
  target_tags   = length(each.value.tags) > 0 ? each.value.tags : null
  description   = each.value.description
}

# =============================================================================
# Static IPs
# =============================================================================

resource "google_compute_address" "ips" {
  for_each = { for ip in local.config.static_ips : ip.name => ip }

  name   = each.value.name
  region = each.value.region
}

# =============================================================================
# Compute Instances — all from terraform.json
# =============================================================================

resource "google_compute_instance" "vms" {
  for_each = { for i in local.config.instances : i.name => i }

  name         = each.value.name
  machine_type = each.value.machine_type
  zone         = local.config.provider.zone
  tags         = each.value.tags

  boot_disk {
    initialize_params {
      image = each.value.image
      size  = each.value.disk_size_gb
      type  = each.value.disk_type
    }
  }

  dynamic "guest_accelerator" {
    for_each = each.value.gpu != null ? [each.value.gpu] : []
    content {
      type  = guest_accelerator.value.type
      count = guest_accelerator.value.count
    }
  }

  network_interface {
    network = google_compute_network.main.name

    access_config {
      nat_ip = each.value.static_ip_name != null ? google_compute_address.ips[each.value.static_ip_name].address : null
    }
  }

  metadata = {
    ssh-keys = "diego:${var.ssh_public_key}"
  }

  scheduling {
    preemptible                 = each.value.preemptible
    automatic_restart           = each.value.automatic_restart
    on_host_maintenance         = each.value.on_host_maintenance
    instance_termination_action = each.value.preemptible ? "STOP" : null
  }

  service_account {
    email  = local.config.service_account.email
    scopes = each.value.scopes
  }

  lifecycle {
    ignore_changes = [boot_disk, metadata]
  }
}

# =============================================================================
# Budget Alerts
# =============================================================================

resource "google_billing_budget" "main" {
  provider        = google-beta
  billing_account = local.config.budget.billing_account
  display_name    = local.config.budget.display_name

  budget_filter {
    projects = ["projects/${local.config.provider.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = local.config.budget.currency
      units         = tostring(local.config.budget.amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = local.config.budget.thresholds
    content {
      threshold_percent = threshold_rules.value
    }
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "static_ips" {
  value       = { for name, ip in google_compute_address.ips : name => ip.address }
  description = "Static public IPs"
}

output "instances" {
  value       = { for name, vm in google_compute_instance.vms : name => vm.network_interface[0].access_config[0].nat_ip }
  description = "Instance IPs"
}
