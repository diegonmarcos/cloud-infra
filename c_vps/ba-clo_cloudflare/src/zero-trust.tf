# Cloudflare One (Zero Trust) — data-driven from terraform.json .zero_trust
# Design: a0_docs/eng-specs/cloudflare-zero-trust.md
#
# Cloudflare is the PRIMARY auth + network edge; Caddy + Authelia on gcp-proxy
# stay deployed as the FALLBACK and are not referenced here at all.
#
# Every address in this file is prefixed `zt_`: the phase-1 pilot runner
# (1_cicd/src/scripts/cloud-cf-zero-trust-pilot.sh) applies ONLY pure creates
# of `*.zt_*` addresses with -target, so unrelated drift in this root is never
# applied by it.
#
# Gate: .zero_trust.org_enabled. While false (Zero Trust not yet enabled on
# the account — the Access API answers access.api.error.not_enabled) only the
# tunnel exists, with a catch-all 404 and NO public hostname: nothing exposed.

locals {
  zt        = local.config.zero_trust
  zt_on     = local.zt.org_enabled
  zt_n      = local.zt_on ? 1 : 0
  zt_tokens = { for t in local.zt.service_tokens : t.key => t }
  zt_dns    = { for r in local.zt.private_dns.records : r.fqdn => r }
}

# =============================================================================
# Tunnel — one remotely-managed tunnel for the fleet (connectors = cloudflared
# replicas on fleet VMs; origins reached over the WireGuard mesh).
# =============================================================================

# Tunnel secret generated inside terraform: it exists only in the sops-encrypted
# state and in the tunnel token exported to sops by the pilot runner.
resource "random_bytes" "zt_tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "zt_fleet" {
  account_id = local.config.account_id
  name       = local.zt.tunnel.name
  secret     = random_bytes.zt_tunnel_secret.base64
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "zt_fleet" {
  account_id = local.config.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.zt_fleet.id

  config {
    # Public hostnames exist only once Access is in front of them.
    dynamic "ingress_rule" {
      for_each = local.zt_on ? [local.zt.pilot_app] : []
      content {
        hostname = ingress_rule.value.hostname
        service  = ingress_rule.value.service
      }
    }
    ingress_rule {
      service = local.zt.tunnel.catchall_service
    }
  }
}

# =============================================================================
# Access — identity (humans) + service tokens (machines) + the pilot app
# =============================================================================

resource "cloudflare_zero_trust_access_identity_provider" "zt_otp" {
  count      = local.zt_n
  account_id = local.config.account_id
  name       = "One-time PIN"
  type       = local.zt.identity.idp
}

resource "cloudflare_zero_trust_access_service_token" "zt_tokens" {
  for_each   = local.zt_on ? local.zt_tokens : {}
  account_id = local.config.account_id
  name       = each.value.name
  duration   = each.value.duration
}

# Reusable policies (account-level), attached to apps via `policies`.
resource "cloudflare_zero_trust_access_policy" "zt_owner" {
  count            = local.zt_n
  account_id       = local.config.account_id
  name             = "zt owner (human SSO)"
  decision         = "allow"
  session_duration = local.zt.identity.session_duration

  include {
    email = local.zt.identity.owner_emails
  }
}

resource "cloudflare_zero_trust_access_policy" "zt_machines" {
  count      = local.zt_n
  account_id = local.config.account_id
  name       = "zt machines (service tokens)"
  decision   = "non_identity"

  include {
    service_token = [for t in cloudflare_zero_trust_access_service_token.zt_tokens : t.id]
  }
}

resource "cloudflare_zero_trust_access_application" "zt_pilot" {
  count                     = local.zt_n
  account_id                = local.config.account_id
  name                      = local.zt.pilot_app.name
  domain                    = local.zt.pilot_app.hostname
  type                      = "self_hosted"
  session_duration          = local.zt.identity.session_duration
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.zt_otp[0].id]
  auto_redirect_to_identity = true
  app_launcher_visible      = true
  # Machines get a 401 instead of a login redirect when their token is bad.
  service_auth_401_redirect = true
  policies = [
    cloudflare_zero_trust_access_policy.zt_owner[0].id,
    cloudflare_zero_trust_access_policy.zt_machines[0].id,
  ]
}

# Proxied CNAME → tunnel. depends_on the Access app: the hostname must never
# resolve to the tunnel before Access protects it. The zone's '*' wildcard is
# DNS-only, so this explicit record overrides it for this one name only.
resource "cloudflare_record" "zt_pilot" {
  count   = local.zt_n
  zone_id = var.cloudflare_zone_id
  name    = local.zt.pilot_app.record_name
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.zt_fleet.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "ZT pilot: tunnel fleet-edge + Access. Fallback stays cloud.diegonmarcos.com/spec (Authelia)"

  depends_on = [cloudflare_zero_trust_access_application.zt_pilot]
}

# =============================================================================
# Gateway — private DNS (DNS location + override policies)
# =============================================================================

resource "cloudflare_zero_trust_dns_location" "zt_fleet" {
  count          = local.zt_n
  account_id     = local.config.account_id
  name           = local.zt.private_dns.location_name
  client_default = false
  ecs_support    = false
}

resource "cloudflare_zero_trust_gateway_policy" "zt_private_dns" {
  for_each    = local.zt_on ? local.zt_dns : {}
  account_id  = local.config.account_id
  name        = "zt private dns: ${each.key}"
  description = "Private name served by Gateway (fleet.internal). Hickory 10.0.0.1 is the fallback resolver."
  precedence  = each.value.precedence
  action      = "override"
  enabled     = true
  filters     = ["dns"]
  traffic     = "dns.fqdn == \"${each.key}\""

  rule_settings {
    override_ips = each.value.ips
  }
}

# =============================================================================
# Outputs — sensitive ones are read only by the pilot runner, which masks them
# and writes them to sops files encrypted to the public age recipient.
# =============================================================================

output "zt_tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.zt_fleet.id
}

output "zt_tunnel_token" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.zt_fleet.tunnel_token
  sensitive = true
}

output "zt_service_token_client_id" {
  value     = local.zt_on ? cloudflare_zero_trust_access_service_token.zt_tokens["pilot"].client_id : ""
  sensitive = true
}

output "zt_service_token_client_secret" {
  value     = local.zt_on ? cloudflare_zero_trust_access_service_token.zt_tokens["pilot"].client_secret : ""
  sensitive = true
}

output "zt_dns_location_doh_subdomain" {
  value = local.zt_on ? cloudflare_zero_trust_dns_location.zt_fleet[0].doh_subdomain : ""
}
