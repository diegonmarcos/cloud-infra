#!/usr/bin/env bash
# Phase A — mail-behind-wg0 unit test.
# Run AFTER `cloud/2_configs/build.sh` regenerates dist/.
# Verifies: user-facing mail ports bind to 10.0.0.3; MX stays public;
#           Caddy l4_routes[] is empty (auto from removed public_ports);
#           l4Map code is still present in derive engine.
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo "[PASS] $label"
    PASS=$(( PASS + 1 ))
  else
    echo "[FAIL] $label"
    FAIL=$(( FAIL + 1 ))
  fi
}

# ── Regenerate dist/ ──────────────────────────────────────────────────────────
echo "==> Regenerating dist/ ..."
./build.sh >/dev/null

MADDY_CONF="../a_solutions/aa-sui_tools-maddy/dist/configs/maddy.conf.tpl"
STALWART_CONF="../a_solutions/aa-sui_tools-stalwart/dist/configs/config.toml"
STALWART_COMPOSE="../a_solutions/aa-sui_tools-stalwart/dist/compose/docker-compose.yml"
CADDY_JSON="dist/build-caddy.json"
DERIVE_SRC="src/engines/cloud-data-config-derive.ts"

# ── Maddy: user-facing ports bind to 10.0.0.3 ───────────────────────────────
check "maddy: SMTPS 465 binds 10.0.0.3" \
  grep -qE 'tls://10\.0\.0\.3:465' "$MADDY_CONF"

check "maddy: Submission 587 binds 10.0.0.3" \
  grep -qE 'tcp://10\.0\.0\.3:587' "$MADDY_CONF"

check "maddy: IMAPS 993 binds 10.0.0.3" \
  grep -qE 'tls://10\.0\.0\.3:993' "$MADDY_CONF"

check "maddy: MX 25 stays on 0.0.0.0 (public)" \
  grep -qE 'smtp tcp://0\.0\.0\.0:25' "$MADDY_CONF"

check "maddy: no 0.0.0.0 on user-facing ports (465/587/993)" \
  bash -c '! grep -E "0\.0\.0\.0:(465|587|993)" '"$MADDY_CONF"

# ── Maddy: also binds 127.0.0.1 for co-located SnappyMail (network_mode: host) ──
check "maddy: IMAPS 993 ALSO binds 127.0.0.1 (loopback for snappymail)" \
  grep -qE 'tls://127\.0\.0\.1:993' "$MADDY_CONF"

check "maddy: SMTPS 465 ALSO binds 127.0.0.1 (loopback for snappymail)" \
  grep -qE 'tls://127\.0\.0\.1:465' "$MADDY_CONF"

# ── SnappyMail: domain.ini uses mail.diegonmarcos.com (matches cert) ──────────
# /etc/hosts on oci-mail overrides it to 127.0.0.1 (loopback). With Maddy
# dual-bind (10.0.0.3 + 127.0.0.1), PHP IMAPS to mail.diegonmarcos.com:993
# resolves loopback and hits Maddy's local listener.
SNAPPY_DOMAIN="../a_solutions/aa-sui_snappymail/dist/configs/domain.ini"
check "snappymail: imap_host = mail.diegonmarcos.com (cert-matching public name)" \
  grep -qE '^imap_host = "mail\.diegonmarcos\.com"' "$SNAPPY_DOMAIN"

check "snappymail: smtp_host = mail.diegonmarcos.com" \
  grep -qE '^smtp_host = "mail\.diegonmarcos\.com"' "$SNAPPY_DOMAIN"

# ── Stalwart: port mappings are WG-only / loopback ───────────────────────────
check "stalwart compose: IMAPS 2993 maps to 10.0.0.3" \
  grep -qE '10\.0\.0\.3:2993:2993' "$STALWART_COMPOSE"

check "stalwart compose: SMTPS 2465 maps to 10.0.0.3" \
  grep -qE '10\.0\.0\.3:2465:2465' "$STALWART_COMPOSE"

check "stalwart compose: Submission 2587 maps to 10.0.0.3" \
  grep -qE '10\.0\.0\.3:2587:2587' "$STALWART_COMPOSE"

check "stalwart compose: HTTPS/JMAP 2443 maps to 10.0.0.3" \
  grep -qE '10\.0\.0\.3:2443:2443' "$STALWART_COMPOSE"

check "stalwart compose: shadow SMTP 2025 maps to 127.0.0.1 (loopback)" \
  grep -qE '127\.0\.0\.1:2025:2025' "$STALWART_COMPOSE"

check "stalwart compose: no 0.0.0.0 on user-facing ports" \
  bash -c '! grep -E "0\.0\.0\.0:(2465|2587|2993|2443|6190)" '"$STALWART_COMPOSE"

# ── Caddy: l4_routes = 7 (Phase 0 restored — gcp-proxy proxies mail publicly) ─
# Phase A's container WG-bind is the real security boundary; L4 on gcp-proxy
# is the trusted WG-peer ingress. Drop-to-0 is a future Phase (WG-peer-only).
check "caddy: l4_routes has 7 mail entries" \
  jq -e '.l4_routes | length == 7' "$CADDY_JSON"

check "caddy: all l4_routes upstream 10.0.0.3 (oci-mail WG IP)" \
  jq -e 'all(.l4_routes[]; .upstream | startswith("10.0.0.3:"))' "$CADDY_JSON"

# ── listen_scope knob: with default config (no listen_scope) no listen field ──
check "derive: no listen field emitted when listen_scope absent (default public)" \
  jq -e 'all(.l4_routes[]; has("listen") | not)' "$CADDY_JSON"

# ── Derive engine: listen_scope + listen field wiring present ────────────────
check "derive: listen_scope branch present in source" \
  grep -q 'listen_scope === "wg"' "$DERIVE_SRC"

check "caddy template: mkL4Block honors route.listen" \
  grep -q 'route.listen or' "../a_solutions/bb-sec_caddy/src/caddyfile.nix"

# ── Derive engine: l4Map code still present (reversibility contract) ──────────
check "derive: l4Map block preserved" \
  grep -q 'const l4Map' "$DERIVE_SRC"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
