# Cloudflare DNS, Email Routing, Tunnel — data-driven from terraform.json
# All record values live in terraform.json; this file is a pure template.

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
  dns    = local.config.dns_records
}

# =============================================================================
# Provider
# =============================================================================

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_key = var.cloudflare_api_key
  email   = var.cloudflare_email
}

# ── Variables (secrets + DKIM keys — injected via tfvars) ────────────────────

variable "cloudflare_api_key" {
  description = "Cloudflare Global API Key"
  type        = string
  sensitive   = true
}

variable "cloudflare_email" {
  description = "Cloudflare account email"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for diegonmarcos.com"
  type        = string
}

variable "dkim_maddy_public_key" {
  description = "Maddy DKIM public key (default._domainkey)"
  type        = string
}

variable "dkim_cf_public_key" {
  description = "Cloudflare Email Routing DKIM key (cf2024-1._domainkey)"
  type        = string
}

variable "dkim_google_public_key" {
  description = "Google Workspace DKIM key (google._domainkey)"
  type        = string
}

variable "ses_verification_token" {
  description = "SES domain verification token (_amazonses TXT record)"
  type        = string
  default     = ""
}

variable "ses_dkim_token_1" {
  description = "SES DKIM token 1 of 3"
  type        = string
  default     = ""
}

variable "ses_dkim_token_2" {
  description = "SES DKIM token 2 of 3"
  type        = string
  default     = ""
}

variable "ses_dkim_token_3" {
  description = "SES DKIM token 3 of 3"
  type        = string
  default     = ""
}

# Map variable names to values for dynamic DKIM lookup
locals {
  dkim_vars = {
    dkim_maddy_public_key  = var.dkim_maddy_public_key
    dkim_cf_public_key     = var.dkim_cf_public_key
    dkim_google_public_key = var.dkim_google_public_key
  }

  ses_dkim_tokens = {
    ses_dkim_token_1 = var.ses_dkim_token_1
    ses_dkim_token_2 = var.ses_dkim_token_2
    ses_dkim_token_3 = var.ses_dkim_token_3
  }
}

# =============================================================================
# DNS Records — A records
#
# Each entry in `a_records` produces:
#   1. One A record at `name` → `proxy_ip` (always — public IP, gcp-proxy edge)
#   2. Optionally one additional A record per IP in `extra_ips` (multi-value
#      DNS — for split-tunnel WG clients that should reach the same service
#      via an internal IP without round-tripping to the public edge).
#
# Multi-value DNS rationale: when a name is configured with extra_ips, a
# client that can reach the internal IP (e.g. phone on wg0) tries it first
# and saves a hairpin through the public edge. Public-only clients drop the
# unreachable internal IP after one connect-failure timeout (~5s) and fall
# back to the proxy_ip — slight one-time lag, no breakage.
#
# Per-record extra_ips are NEVER proxied (Cloudflare proxy can't terminate
# arbitrary protocols against an RFC1918 origin). proxied flag is always
# false for the extras regardless of the primary record's `proxied` setting.
# =============================================================================

locals {
  # Flatten a_records into one entry per (name, ip) pair.
  #
  # Ordering intent: extra_ips first (intended to be wg-mesh internal
  # addresses like 10.0.0.1), proxy_ip last (the public fallback). This
  # is an INTENT marker — Cloudflare's authoritative DNS randomizes the
  # multi-value response order on each query (round-robin), so clients
  # don't see this declaration order verbatim. For deterministic wg-first
  # resolution, point the client at hickory (10.0.0.1:53) which returns
  # the wg IP only.
  #
  # Resource keys: the entry whose ip == proxy_ip keeps key=r.name (state
  # stable with the pre-multi-value schema, regardless of where in the
  # concat it lands); extras get key="${name}-${ip}" so they don't collide.
  a_record_expansions = flatten([
    for r in local.dns.a_records : concat(
      [
        for ip in lookup(r, "extra_ips", []) : {
          key     = "${r.name}-${ip}"
          name    = r.name
          ip      = ip
          proxied = false
          ttl     = r.ttl
          comment = "${r.comment != null ? "${r.comment} " : ""}[multi-value:${ip}]"
        }
      ],
      [
        {
          key     = r.name
          name    = r.name
          ip      = local.config.proxy_ip
          proxied = r.proxied
          ttl     = r.ttl
          comment = r.comment
        }
      ]
    )
  ])
}

resource "cloudflare_record" "a_records" {
  for_each = { for r in local.a_record_expansions : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "A"
  content = each.value.ip
  proxied = each.value.proxied
  ttl     = each.value.ttl
  # Truncate at 100 chars — Cloudflare API rejects longer comments (9313).
  # coalesce shields against null comments (a_records[].comment is nullable).
  comment = substr(coalesce(each.value.comment, ""), 0, 100)

  # Import-on-create: if a record with same name+type already exists in
  # Cloudflare (e.g. from a previous partial-apply that died mid-way), treat
  # it as an update target instead of erroring with 'expected DNS record to
  # not already be present'. The repo is declarative — anything in CF that
  # terraform doesn't track is, by definition, drift to be reconciled.
  allow_overwrite = true
}

# =============================================================================
# DNS Records — CNAME records
# =============================================================================

resource "cloudflare_record" "cname_records" {
  for_each = { for r in local.dns.cname_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "CNAME"
  content = each.value.content
  proxied = each.value.proxied
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — TXT records (SPF, DMARC, SES SPF)
# =============================================================================

resource "cloudflare_record" "txt_records" {
  for_each = { for r in local.dns.txt_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "TXT"
  content = each.value.content
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — DKIM TXT records (content from variables)
# =============================================================================

resource "cloudflare_record" "dkim_records" {
  for_each = { for r in local.dns.dkim_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "TXT"
  content = local.dkim_vars[each.value.var]
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — AWS SES verification + DKIM CNAMEs
# =============================================================================

resource "cloudflare_record" "ses_verification" {
  zone_id = var.cloudflare_zone_id
  name    = local.dns.ses_verification.name
  type    = "TXT"
  content = var.ses_verification_token
  ttl     = local.dns.ses_verification.ttl
  comment = local.dns.ses_verification.comment
}

resource "cloudflare_record" "ses_dkim" {
  for_each = { for r in local.dns.ses_dkim_cnames : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = "${local.ses_dkim_tokens[each.value.var]}._domainkey"
  type    = "CNAME"
  content = "${local.ses_dkim_tokens[each.value.var]}.dkim.amazonses.com"
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — SES MAIL FROM (MX + SPF already in txt_records)
# =============================================================================

resource "cloudflare_record" "ses_mail_from_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = local.dns.ses_mail_from_mx.name
  type     = "MX"
  content  = local.dns.ses_mail_from_mx.content
  priority = local.dns.ses_mail_from_mx.priority
  ttl      = local.dns.ses_mail_from_mx.ttl
  comment  = local.dns.ses_mail_from_mx.comment
}

# =============================================================================
# DNS Records — CAA
# =============================================================================

resource "cloudflare_record" "caa_records" {
  for_each = { for r in local.dns.caa_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "CAA"
  data {
    flags = each.value.flags
    tag   = each.value.tag
    value = each.value.value
  }
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# Cloudflare Tunnel
# =============================================================================

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "tunnels" {
  account_id = local.config.account_id
  tunnel_id  = local.config.tunnel.id

  config {
    dynamic "ingress_rule" {
      for_each = local.config.tunnel.ingress_rules
      content {
        hostname = ingress_rule.value.hostname
        service  = ingress_rule.value.service
      }
    }
    # Catch-all (required by Cloudflare)
    ingress_rule {
      service = local.config.tunnel.catchall_service
    }
  }
}

# =============================================================================
# Email Routing
# =============================================================================

resource "cloudflare_email_routing_address" "backup" {
  account_id = local.config.account_id
  email      = local.config.email_routing.backup_email
}

resource "cloudflare_email_routing_rule" "rules" {
  for_each = { for idx, r in local.config.email_routing.rules : r.name => r }

  zone_id  = var.cloudflare_zone_id
  name     = each.value.name
  enabled  = each.value.enabled
  priority = each.value.priority

  matcher {
    type  = each.value.match_type
    field = each.value.match_field
    value = each.value.match_value
  }

  action {
    type  = each.value.action_type
    value = each.value.action_value
  }
}

# =============================================================================
# SSL/TLS Settings
# =============================================================================

resource "cloudflare_zone_settings_override" "ssl_settings" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = local.config.ssl_settings.ssl
    always_use_https         = local.config.ssl_settings.always_use_https
    min_tls_version          = local.config.ssl_settings.min_tls_version
    automatic_https_rewrites = local.config.ssl_settings.automatic_https_rewrites
    opportunistic_encryption = local.config.ssl_settings.opportunistic_encryption
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "email_architecture" {
  value = "CF Email Routing (MX) → Worker email-forwarder → http-to-smtp-proxy-api (gcp-proxy:8080) → SMTP/WG → maddy :25 + stalwart :2025 (oci-mail)"
}
