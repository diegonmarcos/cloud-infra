# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : c_vps/vps_resend/src/main.tf
# ║   Engine : 1_workflows/src/scripts/cloud-ship-terraform-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Resend — data-driven from terraform.json
# Email delivery service (domain + DNS verification via Cloudflare)

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
  dns    = local.config.dns_records
}

terraform {
  required_providers {
    resend = {
      source  = "y0n0zawa/resend"
      version = "~> 1.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# ── Variables (secrets — injected via tfvars) ────────────────────────────────

variable "resend_api_key" {
  description = "Resend API key (full access)"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit permission"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for diegonmarcos.com"
  type        = string
}

# ── Providers ────────────────────────────────────────────────────────────────

provider "resend" {
  api_key = var.resend_api_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── Resend Domain ────────────────────────────────────────────────────────────

resource "resend_domain" "mail" {
  name   = local.config.domain
  region = local.config.resend_region
}

# ── Cloudflare DNS Records ───────────────────────────────────────────────────

resource "cloudflare_record" "resend_dkim" {
  zone_id = var.cloudflare_zone_id
  name    = local.dns.dkim.name
  type    = "TXT"
  content = resend_domain.mail.records[0].value
  ttl     = 1
  comment = local.dns.dkim.comment
}

resource "cloudflare_record" "resend_spf_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = local.dns.spf_mx.name
  type     = "MX"
  content  = local.dns.spf_mx.content
  priority = local.dns.spf_mx.priority
  ttl      = 1
  comment  = local.dns.spf_mx.comment
}

resource "cloudflare_record" "resend_spf_txt" {
  zone_id = var.cloudflare_zone_id
  name    = local.dns.spf_txt.name
  type    = "TXT"
  content = local.dns.spf_txt.content
  ttl     = 1
  comment = local.dns.spf_txt.comment
}

# ── Verify Domain ────────────────────────────────────────────────────────────

resource "resend_domain_verification" "mail" {
  domain_id = resend_domain.mail.id

  depends_on = [
    cloudflare_record.resend_dkim,
    cloudflare_record.resend_spf_mx,
    cloudflare_record.resend_spf_txt,
  ]
}

# ── Outputs ──────────────────────────────────────────────────────────────────

output "domain_id" {
  description = "Resend domain ID"
  value       = resend_domain.mail.id
}

output "domain_status" {
  description = "Resend domain verification status"
  value       = resend_domain.mail.status
}

output "dns_records" {
  description = "Required DNS records (for reference)"
  value       = resend_domain.mail.records
}
