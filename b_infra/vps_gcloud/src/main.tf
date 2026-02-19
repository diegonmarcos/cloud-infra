terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "diegonmarcos-infra-prod"
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-a"
}

variable "ssh_public_key" {
  description = "SSH public key for diego user"
  type        = string
  # Set via: TF_VAR_ssh_public_key=$(cat ~/git/vault/A0_keys/ssh/google_compute_engine.pub)
  # Or via build.sh which reads from vault automatically
}

# =============================================================================
# VPC Network - GCP default (auto-created, cannot be deleted)
# =============================================================================

resource "google_compute_network" "main" {
  name                    = "default"
  description             = "Default network for the project"
  auto_create_subnetworks = true

  lifecycle {
    prevent_destroy = true  # GCP default network cannot be recreated
  }
}

# =============================================================================
# Firewall Rules
# NOTE: default-allow-icmp, default-allow-internal, default-allow-rdp,
#       default-allow-ssh are GCP auto-created defaults — NOT managed here.
# =============================================================================

resource "google_compute_firewall" "allow_flask_api" {
  name    = "allow-flask-api"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["5000"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow Flask API on port 5000"
}

resource "google_compute_firewall" "allow_http" {
  name    = "allow-http"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
  description   = "Allow HTTP traffic"
}

resource "google_compute_firewall" "allow_https" {
  name    = "allow-https"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["https-server"]
  description   = "Allow HTTPS traffic"
}

resource "google_compute_firewall" "allow_mail_imaps" {
  name    = "allow-mail-imaps"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["993"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow IMAPS"
}

resource "google_compute_firewall" "allow_mail_smtp" {
  name    = "allow-mail-smtp"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["25"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow SMTP"
}

resource "google_compute_firewall" "allow_mail_submission" {
  name    = "allow-mail-submission"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["587"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow SMTP Submission"
}

resource "google_compute_firewall" "allow_wireguard" {
  name    = "allow-wireguard"
  network = google_compute_network.main.name

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "WireGuard from Oracle VM"
}

# =============================================================================
# Static IPs
# =============================================================================

resource "google_compute_address" "proxy_ip" {
  name   = "arch-1-ip"
  region = var.region
}

# =============================================================================
# Compute Instances
# =============================================================================

# gcp-proxy (arch-1) — always-on free tier e2-micro (Fedora, despite the name)
resource "google_compute_instance" "central_proxy" {
  name         = "arch-1"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["http-server", "https-server", "npm-admin"]

  boot_disk {
    initialize_params {
      image = "projects/fedora-cloud/global/images/family/fedora-cloud-42"
      size  = 32
      type  = "pd-standard"
    }
  }

  network_interface {
    network = google_compute_network.main.name

    access_config {
      nat_ip = google_compute_address.proxy_ip.address
    }
  }

  metadata = {
    ssh-keys = "diego:${var.ssh_public_key}"
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
  }

  service_account {
    email = "514615763870-compute@developer.gserviceaccount.com"
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/pubsub",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }

  lifecycle {
    ignore_changes = [boot_disk, metadata]  # Avoid re-imaging running instance
  }
}

# gcp-ollama (ollama-spot-gpu) — spot T4 GPU, started on demand
resource "google_compute_instance" "ollama_gpu" {
  name         = "ollama-spot-gpu"
  machine_type = "n1-standard-4"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
      size  = 50
      type  = "pd-standard"
    }
  }

  guest_accelerator {
    type  = "nvidia-tesla-t4"
    count = 1
  }

  network_interface {
    network = google_compute_network.main.name
    access_config {}  # Ephemeral IP — spot instances change IP on restart
  }

  metadata = {
    ssh-keys = "diego:${var.ssh_public_key}"
  }

  scheduling {
    preemptible                 = true
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"  # Required for GPU instances
    instance_termination_action = "STOP"
  }

  service_account {
    email  = "514615763870-compute@developer.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  lifecycle {
    ignore_changes = [boot_disk, metadata]
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "proxy_ip" {
  value       = google_compute_address.proxy_ip.address
  description = "Static public IP of gcp-proxy (35.226.147.64)"
}

output "proxy_ssh" {
  value       = "ssh gcp-proxy"
  description = "SSH alias for gcp-proxy"
}
