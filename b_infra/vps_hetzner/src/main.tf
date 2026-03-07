# Hetzner Cloud Infrastructure
# Currently placeholder — no active resources.
# Add hcloud_server resources here when provisioning.

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
