#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/scripts/cloud-ship-ci-setup-wireguard.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Setup WireGuard interface for GHA runner / cloud-builder
# Requires: WG_PRIVATE_KEY env var, wireguard-tools + iproute2 + jq installed
# Connects to hub at gcp-proxy via WireGuard mesh.
#
# Data-driven: all topology values (hub IP, hub pubkey, ports, subnet,
# client wg_ip) are read from cloud/config.json#native.wireguard.
# Hub VM IP read from vms[wg_hub].ip.
#
# Endpoint selection (Phase 4 hub-side NAT redirect on gcp-proxy):
#   primary  -> native.wireguard.port           (default udp/51820)
#   fallback -> native.wireguard.port_fallback  (default udp/443)
# Set WG_ENDPOINT_MODE=fallback in the runner env to use the fallback port
# (e.g. when the runner network blocks udp/51820).
set -e

if [ -z "${WG_PRIVATE_KEY:-}" ]; then
  echo "[wireguard] Skipped (no WG_PRIVATE_KEY)"
  exit 0
fi

# Locate config.json — script may run from CI checkout or local dev
CONFIG_JSON="${CLOUD_CONFIG_JSON:-}"
if [ -z "$CONFIG_JSON" ]; then
  for candidate in \
    "${GITHUB_WORKSPACE:-}/config.json" \
    "$(git rev-parse --show-toplevel 2>/dev/null)/config.json" \
    "$(dirname "$0")/../../../../config.json"
  do
    [ -f "$candidate" ] && CONFIG_JSON="$candidate" && break
  done
fi
if [ ! -f "$CONFIG_JSON" ]; then
  echo "[wireguard] FATAL: cloud/config.json not found (set CLOUD_CONFIG_JSON)" >&2
  exit 1
fi
echo "[wireguard] Reading topology from $CONFIG_JSON"

WG=$(jq -c '.native.wireguard' "$CONFIG_JSON")
HUB_VM=$(echo "$WG" | jq -r '.wg_hub')
HUB_IP=$(jq -r --arg h "$HUB_VM" '.vms[$h].ip' "$CONFIG_JSON")
HUB_PUBKEY=$(jq -r --arg h "$HUB_VM" '.vms[$h].wg_public_key' "$CONFIG_JSON")
if [ -z "$HUB_PUBKEY" ] || [ "$HUB_PUBKEY" = "null" ]; then
  HUB_PUBKEY="${WG_HUB_PUBKEY:-}"
fi
if [ -z "$HUB_PUBKEY" ]; then
  echo "[wireguard] FATAL: hub public key not in config.json and WG_HUB_PUBKEY unset" >&2
  exit 1
fi
SUBNET=$(echo "$WG"   | jq -r '.subnet')
PORT_PRIMARY=$(echo "$WG"  | jq -r '.port')
PORT_FALLBACK=$(echo "$WG" | jq -r '.port_fallback // empty')
CLIENT_WG_IP=$(echo "$WG" | jq -r '.clients["gha-runner"].wg_ip')

MODE="${WG_ENDPOINT_MODE:-primary}"
if [ "$MODE" = "fallback" ]; then
  if [ -z "$PORT_FALLBACK" ]; then
    echo "[wireguard] FATAL: WG_ENDPOINT_MODE=fallback but native.wireguard.port_fallback not set in config.json" >&2
    exit 1
  fi
  HUB_PORT="$PORT_FALLBACK"
else
  HUB_PORT="$PORT_PRIMARY"
fi

# Install wireguard-tools if missing (idempotent — no-op on self-hosted runners where wg-quick exists).
if ! command -v wg-quick >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  echo "[wireguard] installing wireguard-tools"
  sudo apt-get update -qq && sudo apt-get install -y -qq wireguard-tools iproute2
fi

echo "[wireguard] Setting up WireGuard (mode=$MODE) -> $HUB_IP:$HUB_PORT"
umask 077
cat > /tmp/wg0.conf << WGEOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${CLIENT_WG_IP}/24

[Peer]
PublicKey = ${HUB_PUBKEY}
Endpoint = ${HUB_IP}:${HUB_PORT}
AllowedIPs = ${SUBNET}
PersistentKeepalive = 25
WGEOF

SUDO=""
command -v sudo >/dev/null 2>&1 && SUDO="sudo"
$SUDO mkdir -p /etc/wireguard
$SUDO cp /tmp/wg0.conf /etc/wireguard/wg0.conf
rm /tmp/wg0.conf
$SUDO wg-quick up wg0
HUB_WG_IP=$(echo "$WG" | jq -r --arg h "$HUB_VM" '.peers // [] | map(select(.name==$h))[0].wg_ip // "10.0.0.1"' "$CONFIG_JSON" 2>/dev/null || echo "10.0.0.1")
ping -c1 -W3 "$HUB_WG_IP" >/dev/null 2>&1 \
  && echo "[wireguard] Hub reachable ($HUB_WG_IP)" \
  || echo "[wireguard] Hub not reachable (may need time)"
