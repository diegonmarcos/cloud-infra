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
      version = local.config.provider.version
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
