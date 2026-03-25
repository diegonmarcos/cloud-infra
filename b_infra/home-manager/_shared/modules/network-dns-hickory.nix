# Configure DNS resolvers for all VMs — reads from cloud-data-home-manager.json
# Primary (Hickory) serves .app zones, forwards everything else to fallback.
# /etc/resolv.conf is made IMMUTABLE so Docker can't overwrite it.
# Docker daemon.json also configured with DNS.
{ config, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
  primaryDns = cloudData.dns.primary;
  fallbackDns = cloudData.dns.fallback;
in {
  home.activation.configureHickoryDns = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[hickory-dns] no sudo — skipping" && exit 0

    # ── 1. /etc/resolv.conf — primary first, fallback second ──
    $SUDO chattr -i /etc/resolv.conf 2>/dev/null || true
    if [ -L /etc/resolv.conf ]; then
      $SUDO rm /etc/resolv.conf
    fi
    $SUDO tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver ${primaryDns}
nameserver ${fallbackDns}
EOF
    $SUDO chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "[hickory-dns] resolv.conf → ${primaryDns} (immutable)"

    # ── 2. Docker daemon DNS ──
    $SUDO mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
      $SUDO python3 -c "
import json, sys
try:
    d = json.load(open('/etc/docker/daemon.json'))
except: d = {}
d['dns'] = ['${primaryDns}', '${fallbackDns}']
json.dump(d, open('/etc/docker/daemon.json','w'), indent=2)
print('[hickory-dns] Docker daemon.json updated: dns=[${primaryDns}, ${fallbackDns}]')
" 2>/dev/null || echo "[hickory-dns] WARN: could not update daemon.json"
    else
      echo '{"dns": ["${primaryDns}", "${fallbackDns}"]}' | $SUDO tee /etc/docker/daemon.json >/dev/null
      echo "[hickory-dns] Docker daemon.json created"
    fi

    $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
