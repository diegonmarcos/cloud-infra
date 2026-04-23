# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : c_vps/vps_hetzner/src/main.tf
# ║   Engine : 1_workflows/src/scripts/cloud-ship-terraform-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Hetzner Cloud Infrastructure — data-driven from terraform.json
# Currently placeholder — no active resources.
# Add instances/resources to terraform.json when provisioning.

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
}

terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

provider "hcloud" {
  token = var.hcloud_token
}
