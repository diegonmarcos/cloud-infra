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
    $SUDO tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 10.0.0.1
nameserver 1.1.1.1
EOF
    # Clean up old resolved drop-in if present
    $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    echo "[hickory-dns] resolv.conf → nameserver 10.0.0.1 (Hickory)"
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
