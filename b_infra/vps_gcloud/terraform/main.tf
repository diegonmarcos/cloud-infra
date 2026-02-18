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
  description = "SSH public key content for diego user"
  type        = string
  # Set via: TF_VAR_ssh_public_key=$(cat ~/git/vault/A0_keys/ssh/google_compute_engine.pub)
}

# =============================================================================
# VPC Network
# =============================================================================

resource "google_compute_network" "main" {
  name                    = "main-network"
  auto_create_subnetworks = true
}

# =============================================================================
# Firewall Rules
# =============================================================================

# Allow SSH from anywhere (key-based auth only)
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh-enabled"]
  description   = "Allow SSH access (key-based auth only)"
}

# Allow HTTP/HTTPS + HTTP3 (Caddy on gcp-proxy only)
resource "google_compute_firewall" "allow_web" {
  name    = "allow-web"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  allow {
    protocol = "udp"
    ports    = ["443"]  # HTTP/3 (QUIC)
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web-server"]
  description   = "Allow HTTP, HTTPS and HTTP/3 (Caddy)"
}

# Allow WireGuard VPN
resource "google_compute_firewall" "allow_wireguard" {
  name    = "allow-wireguard"
  network = google_compute_network.main.name

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["wireguard"]
  description   = "Allow WireGuard VPN traffic"
}

# Allow Syslog from all OCI VMs (over WireGuard mesh)
resource "google_compute_firewall" "allow_syslog" {
  name    = "allow-syslog"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["514", "5514"]
  }

  allow {
    protocol = "udp"
    ports    = ["514"]
  }

  source_ranges = [
    "130.110.251.193/32",  # oci-E2-f_0 (oci-mail)
    "129.151.228.66/32",   # oci-E2-f_1 (oci-analytics)
    "82.70.229.129/32",    # oci-A1-f_0 (oci-apps)
    "144.24.196.72/32",    # oci-A1-f_1 (oci-apps-1)
    "79.72.28.10/32"       # oci-A1-p_0 (oci-apps-2)
  ]
  target_tags   = ["syslog-server"]
  description   = "Allow syslog from all OCI VMs"
}

# Allow ICMP (ping)
resource "google_compute_firewall" "allow_icmp" {
  name    = "allow-icmp"
  network = google_compute_network.main.name

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow ICMP for diagnostics"
}

# =============================================================================
# Static IPs
# =============================================================================

resource "google_compute_address" "proxy_ip" {
  name   = "central-proxy-ip"
  region = var.region
}

# =============================================================================
# Compute Instances
# =============================================================================

# gcp-proxy (arch-1) — always-on free tier e2-micro
resource "google_compute_instance" "central_proxy" {
  name         = "arch-1"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["ssh-enabled", "web-server", "wireguard", "syslog-server"]

  boot_disk {
    initialize_params {
      image = "projects/arch-linux-gce/global/images/family/arch"
      size  = 30
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
    scopes = ["cloud-platform"]
  }

  labels = {
    environment = "production"
    role        = "central-proxy"
    managed_by  = "terraform"
  }
}

# gcp-ollama (ollama-spot-gpu) — spot T4 GPU, started on demand
resource "google_compute_instance" "ollama_gpu" {
  name         = "ollama-spot-gpu"
  machine_type = "n1-standard-4"
  zone         = var.zone

  tags = ["ssh-enabled", "wireguard"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = 50
      type  = "pd-balanced"
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
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"  # Required for GPU instances
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  labels = {
    environment = "production"
    role        = "ollama-gpu"
    managed_by  = "terraform"
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "proxy_ip" {
  value       = google_compute_address.proxy_ip.address
  description = "Static public IP of gcp-proxy"
}

output "proxy_ssh" {
  value       = "gcloud compute ssh arch-1 --zone us-central1-a"
  description = "SSH command for gcp-proxy"
}

output "ollama_ssh" {
  value       = "gcloud compute ssh ollama-spot-gpu --zone us-central1-a"
  description = "SSH command for gcp-ollama (only when running)"
}

output "firewall_rules" {
  value = [
    "allow-ssh      (22/tcp)",
    "allow-web      (80,443/tcp + 443/udp HTTP3)",
    "allow-wireguard (51820/udp)",
    "allow-syslog   (514,5514/tcp+udp — OCI VMs only)",
    "allow-icmp"
  ]
  description = "Configured firewall rules"
}
