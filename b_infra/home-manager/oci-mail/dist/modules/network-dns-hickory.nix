# Configure DNS resolvers for all VMs — reads from cloud-data-home-manager.json
# /etc/resolv.conf ONLY — Docker daemon.json is owned by container-init.nix
# resolv.conf is made IMMUTABLE so Docker/systemd-resolved can't overwrite it.
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

    # /etc/resolv.conf — primary first, fallback second
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

    # Docker daemon.json is owned by container-init.nix — DO NOT touch it here
    $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
