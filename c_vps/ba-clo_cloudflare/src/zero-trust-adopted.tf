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
  # live login_design is {} and no custom pages: the provider models both as blocks
  # and would plan an empty-block update every run.
  lifecycle { ignore_changes = [login_design, custom_pages] }
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
  # policy_id is not returned for the default profile; import leaves it unset.
  lifecycle { ignore_changes = [policy_id] }
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
  # it is not managed (a diff on secret or config_src would otherwise force replacing the tunnel).
  lifecycle { ignore_changes = [secret, config_src] }
}

import {
  to = cloudflare_zero_trust_tunnel_cloudflared.zt_smtp_proxy
  id = "${local.config.account_id}/${local.zt_ad.smtp_tunnel.id}"
}

# =============================================================================
# Remaining account-level Zero Trust settings (#994): WARP fallback domains, the
# account device/proxy settings + TLS decrypt switch (gateway settings), the
# Gateway-managed CA certificate and the two built-in device posture rules.
# GATED by var.zt_adopt_settings / .zero_trust.adopted.settings_enabled so the very
# first plan can be run from main (workflow_dispatch input adopt_settings) with
# nothing live or in state touched until that plan shows zero changes.
# =============================================================================

variable "zt_adopt_settings" {
  type    = bool
  default = false
}

locals {
  zt_set_on = (local.zt_n == 1) && (var.zt_adopt_settings || try(local.zt_ad.settings_enabled, false))
  zt_set_n  = local.zt_set_on ? 1 : 0
  zt_set_imp = { for i in range(local.zt_set_n) : tostring(i) => i }
}

resource "cloudflare_zero_trust_local_fallback_domain" "zt_fallback" {
  count      = local.zt_set_n
  account_id = local.config.account_id
  dynamic "domains" {
    for_each = local.zt_ad.fallback_domains
    content {
      suffix = domains.value
    }
  }
}

import {
  for_each = local.zt_set_imp
  to       = cloudflare_zero_trust_local_fallback_domain.zt_fallback[each.value]
  id       = local.config.account_id
}

resource "cloudflare_zero_trust_gateway_certificate" "zt_gateway_ca" {
  count           = local.zt_set_n
  account_id      = local.config.account_id
  gateway_managed = true
  activate        = true
  lifecycle { ignore_changes = [validity_period_days, activate, gateway_managed, custom] }
}

import {
  for_each = local.zt_set_imp
  to       = cloudflare_zero_trust_gateway_certificate.zt_gateway_ca[each.value]
  id       = "${local.config.account_id}/${local.zt_ad.gateway_certificate_id}"
}

resource "cloudflare_zero_trust_gateway_settings" "zt_gateway" {
  count                = local.zt_set_n
  account_id           = local.config.account_id
  tls_decrypt_enabled  = false
  certificate {
    id = cloudflare_zero_trust_gateway_certificate.zt_gateway_ca[0].id
  }
  proxy {
    tcp              = true
    udp              = true
    root_ca          = false
    virtual_ip       = true
    disable_for_time = 0
  }
  # Everything else is unset live (antivirus, block page, logging, fips, ...): the
  # provider models those as blocks and would plan empty-block updates every run.
  lifecycle { ignore_changes = [antivirus, block_page, body_scanning, extended_email_matching, fips, logging, payload_log, ssh_session_log, activity_log_enabled, protocol_detection_enabled, non_identity_browser_isolation_enabled, url_browser_isolation_enabled, custom_certificate] }
}

import {
  for_each = local.zt_set_imp
  to       = cloudflare_zero_trust_gateway_settings.zt_gateway[each.value]
  id       = local.config.account_id
}

# Built-in posture rules (created by Cloudflare when the org was created).
resource "cloudflare_zero_trust_device_posture_rule" "zt_posture_gateway" {
  count      = local.zt_set_n
  account_id = local.config.account_id
  type       = "gateway"
  name       = "Gateway"
  lifecycle { ignore_changes = [description, schedule, expiration, match, input] }
}

import {
  for_each = local.zt_set_imp
  to       = cloudflare_zero_trust_device_posture_rule.zt_posture_gateway[each.value]
  id       = "${local.config.account_id}/${local.zt_ad.posture_rule_ids.gateway}"
}

resource "cloudflare_zero_trust_device_posture_rule" "zt_posture_warp" {
  count      = local.zt_set_n
  account_id = local.config.account_id
  type       = "warp"
  name       = "WARP"
  lifecycle { ignore_changes = [description, schedule, expiration, match, input] }
}

import {
  for_each = local.zt_set_imp
  to       = cloudflare_zero_trust_device_posture_rule.zt_posture_warp[each.value]
  id       = "${local.config.account_id}/${local.zt_ad.posture_rule_ids.warp}"
}
