# =============================================================================
# Adopted live objects (#994): the Access org, the default vnet, the default WARP
# profile + its split-tunnel excludes, and the old smtp-proxy-tunnel existed on the
# account before / outside this code. Terraform IMPORTS them (import blocks), so the
# live account == the repo. A plan that shows any change on these means the values in
# terraform.json .zero_trust.adopted are wrong; nothing live is ever modified by the
# import itself. Addresses keep the zt_ prefix so the pilot runner covers them.
# =============================================================================

locals {
  zt_ad = local.zt.adopted
  zt_split_exclude = [for s in local.zt_ad.warp_split_exclude : {
    address     = split("|", s)[0]
    description = length(split("|", s)) > 1 ? split("|", s)[1] : null
  }]
}

resource "cloudflare_zero_trust_access_organization" "zt_org" {
  count       = local.zt_n
  account_id  = local.config.account_id
  name        = local.zt_ad.org.name
  auth_domain = local.zt_ad.org.auth_domain
}

import {
  to       = cloudflare_zero_trust_access_organization.zt_org[0]
  id       = local.config.account_id
}

resource "cloudflare_zero_trust_tunnel_virtual_network" "zt_vnet" {
  count              = local.zt_n
  account_id         = local.config.account_id
  name               = local.zt_ad.vnet.name
  comment            = local.zt_ad.vnet.comment
  is_default_network = true
}

import {
  to       = cloudflare_zero_trust_tunnel_virtual_network.zt_vnet[0]
  id       = "${local.config.account_id}/${local.zt_ad.vnet.id}"
}

# The account's DEFAULT WARP profile (id "default"). Only the fields the account
# shows today; split-tunnel excludes are the separate resource below.
resource "cloudflare_zero_trust_device_profiles" "zt_warp_default" {
  count                 = local.zt_n
  account_id            = local.config.account_id
  name                  = "Default"
  description           = ""
  default               = true
  enabled               = true
  allow_mode_switch     = false
  allow_updates         = false
  allowed_to_leave      = true
  auto_connect          = 0
  captive_portal        = 180
  disable_auto_fallback = false
  exclude_office_ips    = false
  service_mode_v2_mode  = "warp"
  support_url           = ""
  switch_locked         = false
  tunnel_protocol       = "masque"
  lifecycle { ignore_changes = [name, description] }
}

import {
  to       = cloudflare_zero_trust_device_profiles.zt_warp_default[0]
  id       = "${local.config.account_id}/default"
}

resource "cloudflare_zero_trust_split_tunnel" "zt_warp_exclude" {
  count      = local.zt_n
  account_id = local.config.account_id
  mode       = "exclude"
  dynamic "tunnels" {
    for_each = local.zt_split_exclude
    content {
      address     = tunnels.value.address
      description = tunnels.value.description
    }
  }
}

import {
  to       = cloudflare_zero_trust_split_tunnel.zt_warp_exclude[0]
  id       = "${local.config.account_id}/default/exclude"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "zt_smtp_proxy" {
  account_id = local.config.account_id
  name       = local.zt_ad.smtp_tunnel.name
  secret     = random_bytes.zt_tunnel_secret.base64
  config_src = "cloudflare"
  # The tunnel password is write-only on the API: it can never be read back, so
  # it is not managed (a diff here would otherwise force replacing a tunnel).
  lifecycle { ignore_changes = [secret] }
}

import {
  to = cloudflare_zero_trust_tunnel_cloudflared.zt_smtp_proxy
  id = "${local.config.account_id}/${local.zt_ad.smtp_tunnel.id}"
}
