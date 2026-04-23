# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-mail/src/pilot/network/dns-hickory.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Configure DNS resolvers for all VMs — reads from cloud-data-home-manager.json
# Uses resolvconf to maintain proper DNS hierarchy:
#   Tier 1: Hickory (10.0.0.1) — .app private domains + forwarding
#   Tier 2: Cloudflare (1.1.1.1, 1.0.0.1) — fallback
#   Tier 3: Google (8.8.8.8) — last resort
# Docker daemon.json DNS is owned by container-init.nix
{ config, lib, pkgs, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ../cloud-data-home-manager.json);
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

    # Use resolvconf if available (NixOS, Arch with openresolv)
    RESOLVCONF=""
    for p in /run/current-system/sw/bin/resolvconf /usr/bin/resolvconf; do
      [ -x "$p" ] && RESOLVCONF="$p" && break
    done

    if [ -n "$RESOLVCONF" ]; then
      # resolvconf method — proper DNS hierarchy
      echo "nameserver ${primaryDns}" | $SUDO $RESOLVCONF -a hickory
      echo "nameserver ${fallbackDns}" | $SUDO $RESOLVCONF -a hickory-fallback
      echo "[hickory-dns] resolvconf → ${primaryDns} (tier 1)"
    else
      # Fallback: direct write (Arch VMs without resolvconf)
      $SUDO chattr -i /etc/resolv.conf 2>/dev/null || true
      [ -L /etc/resolv.conf ] && $SUDO rm /etc/resolv.conf
      $SUDO tee /etc/resolv.conf > /dev/null <<DNSEOF
nameserver ${primaryDns}
nameserver ${fallbackDns}
nameserver 8.8.8.8
DNSEOF
      $SUDO chattr +i /etc/resolv.conf 2>/dev/null || true
      echo "[hickory-dns] resolv.conf → ${primaryDns} (direct write, immutable)"
    fi

    $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
