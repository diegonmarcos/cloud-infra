#!/bin/bash
# Setup WireGuard on GHA runner to join the mesh
# Requires: WG_PRIVATE_KEY secret
# Assigns: 10.0.0.200/24 → routes through gcp-proxy hub
set -euo pipefail

echo "[wg-setup] Installing WireGuard..."
sudo apt-get update -qq && sudo apt-get install -y -qq wireguard-tools > /dev/null

echo "[wg-setup] Configuring wg0..."
umask 077
cat > /tmp/wg0.conf << 'EOF'
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = 10.0.0.200/24

[Peer]
PublicKey = vV/phXUwnCjxACQ5Df11Uw47BzJaK4r85jPYMu2HmDc=
Endpoint = 35.226.147.64:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

# Replace env var in config
sed -i "s|\${WG_PRIVATE_KEY}|${WG_PRIVATE_KEY}|g" /tmp/wg0.conf

sudo cp /tmp/wg0.conf /etc/wireguard/wg0.conf
rm /tmp/wg0.conf

echo "[wg-setup] Starting wg0..."
sudo wg-quick up wg0

echo "[wg-setup] Verifying connectivity..."
ping -c1 -W3 10.0.0.1 && echo "[wg-setup] ✅ Hub reachable" || echo "[wg-setup] ⚠️ Hub not reachable (may need time)"

echo "[wg-setup] WG mesh joined as 10.0.0.200"
sudo wg show wg0
