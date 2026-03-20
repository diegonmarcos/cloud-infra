# ═══════════════════════════════════════════════════════════════════════════════
# Resend — Email delivery service (domain + DNS verification)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Resend sends transactional/health-check emails via Amazon SES.
# We register mail.diegonmarcos.com (subdomain) to isolate reputation
# from Mailu's root-domain DKIM/SPF.
#
# DNS records are created in Cloudflare. Resend verification is triggered
# after records propagate.
#
# Provider: y0n0zawa/resend (community)
# Docs: https://registry.terraform.io/providers/y0n0zawa/resend/latest
# ═══════════════════════════════════════════════════════════════════════════════

terraform {
  required_providers {
    resend = {
      source  = "y0n0zawa/resend"
      version = "~> 0.2"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

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

variable "domain" {
  description = "Subdomain to register with Resend"
  type        = string
  default     = "mail.diegonmarcos.com"
}

# ── Providers ─────────────────────────────────────────────────────────────────

provider "resend" {
  api_key = var.resend_api_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── Resend Domain ─────────────────────────────────────────────────────────────

resource "resend_domain" "mail" {
  name   = var.domain
  region = "us-east-1"
}

# ── Cloudflare DNS Records (from Resend's required records) ───────────────────

# DKIM — Resend's own signing key (separate selector from Mailu's dkim._domainkey)
resource "cloudflare_record" "resend_dkim" {
  zone_id = var.cloudflare_zone_id
  name    = "resend._domainkey.mail"
  type    = "TXT"
  content = resend_domain.mail.records[0].value
  ttl     = 1 # Auto
  comment = "Resend DKIM for mail.diegonmarcos.com"
}

# SPF MX — Resend bounce handling (send.mail subdomain)
resource "cloudflare_record" "resend_spf_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = "send.mail"
  type     = "MX"
  content  = "feedback-smtp.us-east-1.amazonses.com"
  priority = 10
  ttl      = 1 # Auto
  comment  = "Resend SPF MX for mail.diegonmarcos.com"
}

# SPF TXT — Resend SPF (send.mail subdomain)
resource "cloudflare_record" "resend_spf_txt" {
  zone_id = var.cloudflare_zone_id
  name    = "send.mail"
  type    = "TXT"
  content = "v=spf1 include:amazonses.com ~all"
  ttl     = 1 # Auto
  comment = "Resend SPF for mail.diegonmarcos.com"
}

# ── Verify Domain ─────────────────────────────────────────────────────────────

resource "resend_domain_verification" "mail" {
  domain_id = resend_domain.mail.id

  depends_on = [
    cloudflare_record.resend_dkim,
    cloudflare_record.resend_spf_mx,
    cloudflare_record.resend_spf_txt,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

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
