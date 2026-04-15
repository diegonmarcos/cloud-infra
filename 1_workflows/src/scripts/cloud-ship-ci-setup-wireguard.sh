#!/usr/bin/env bash
# Setup WireGuard interface for GHA runner / cloud-builder
# Requires: WG_PRIVATE_KEY env var, wireguard-tools + iproute2 installed
# Connects to hub at gcp-proxy (10.0.0.1) via WireGuard mesh
set -e

if [ -z "${WG_PRIVATE_KEY:-}" ]; then
  echo "[wireguard] Skipped (no WG_PRIVATE_KEY)"
  exit 0
fi

echo "[wireguard] Setting up WireGuard"
umask 077
cat > /tmp/wg0.conf << WGEOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = 10.0.0.200/24

[Peer]
PublicKey = vV/phXUwnCjxACQ5Df11Uw47BzJaK4r85jPYMu2HmDc=
Endpoint = 35.226.147.64:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
WGEOF

mkdir -p /etc/wireguard
cp /tmp/wg0.conf /etc/wireguard/wg0.conf
rm /tmp/wg0.conf
wg-quick up wg0
ping -c1 -W3 10.0.0.1 >/dev/null 2>&1 && echo "[wireguard] Hub reachable (10.0.0.1)" || echo "[wireguard] Hub not reachable (may need time)"
