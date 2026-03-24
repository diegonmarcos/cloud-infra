# Configure Hickory DNS (10.0.0.1) as primary resolver for all VMs
# Hickory serves .app zones locally, forwards everything else to Cloudflare.
# This replaces systemd-resolved with a direct /etc/resolv.conf.
{ config, lib, ... }:
{
  home.activation.configureHickoryDns = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[hickory-dns] no sudo — skipping" && exit 0

    # Remove systemd-resolved symlink and write direct resolv.conf
    if [ -L /etc/resolv.conf ]; then
      $SUDO rm /etc/resolv.conf
    fi
    # Remove immutable flag if previously set (so we can update)
    $SUDO chattr -i /etc/resolv.conf 2>/dev/null || true
    $SUDO tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 10.0.0.1
nameserver 1.1.1.1
EOF
    # Make immutable so Docker can't overwrite on container restart
    $SUDO chattr +i /etc/resolv.conf 2>/dev/null || true
    # Also configure Docker daemon DNS (belt + suspenders)
    $SUDO mkdir -p /etc/docker
    if ! grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
      if [ -f /etc/docker/daemon.json ]; then
        # Merge dns into existing config
        $SUDO python3 -c "
import json
d = json.load(open('/etc/docker/daemon.json'))
d['dns'] = ['10.0.0.1', '1.1.1.1']
json.dump(d, open('/etc/docker/daemon.json','w'), indent=2)
" 2>/dev/null || true
      else
        echo '{"dns": ["10.0.0.1", "1.1.1.1"]}' | $SUDO tee /etc/docker/daemon.json >/dev/null
      fi
      echo "[hickory-dns] Docker daemon DNS configured"
    fi
    # Clean up old resolved drop-in if present
    $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    echo "[hickory-dns] resolv.conf → 10.0.0.1 (immutable + Docker daemon DNS)"
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
