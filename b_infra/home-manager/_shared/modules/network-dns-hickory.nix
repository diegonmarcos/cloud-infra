# Configure Hickory DNS (10.0.0.1) as primary resolver for all VMs
# Hickory serves .app zones locally, forwards everything else to Cloudflare.
# /etc/resolv.conf is made IMMUTABLE so Docker can't overwrite it.
# Docker daemon.json also configured with Hickory DNS as fallback.
{ config, lib, ... }:
{
  home.activation.configureHickoryDns = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[hickory-dns] no sudo — skipping" && exit 0

    # ── 1. /etc/resolv.conf — Hickory first, Cloudflare fallback ──
    # Remove immutable flag if previously set (so we can update)
    $SUDO chattr -i /etc/resolv.conf 2>/dev/null || true
    # Remove systemd-resolved symlink
    if [ -L /etc/resolv.conf ]; then
      $SUDO rm /etc/resolv.conf
    fi
    $SUDO tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 10.0.0.1
nameserver 1.1.1.1
EOF
    # Make IMMUTABLE — Docker cannot overwrite on container restart
    $SUDO chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "[hickory-dns] resolv.conf → 10.0.0.1 (immutable)"

    # ── 2. Docker daemon DNS — belt + suspenders ──
    $SUDO mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
      # Merge dns into existing config (preserve other settings)
      $SUDO python3 -c "
import json, sys
try:
    d = json.load(open('/etc/docker/daemon.json'))
except: d = {}
d['dns'] = ['10.0.0.1', '1.1.1.1']
json.dump(d, open('/etc/docker/daemon.json','w'), indent=2)
print('[hickory-dns] Docker daemon.json updated: dns=[10.0.0.1, 1.1.1.1]')
" 2>/dev/null || echo "[hickory-dns] WARN: could not update daemon.json"
    else
      echo '{"dns": ["10.0.0.1", "1.1.1.1"]}' | $SUDO tee /etc/docker/daemon.json >/dev/null
      echo "[hickory-dns] Docker daemon.json created"
    fi

    # Clean up old resolved drop-in if present
    $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
