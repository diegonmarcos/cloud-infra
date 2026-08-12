# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloud/b_infra/nixhm-sudo-oci-analytics/src/pilot/network/ipv6-guest.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ipv6-guest.nix — bring the OCI-assigned IPv6 UP INSIDE THE GUEST.
#
# ENABLED ONLY ON: oci-analytics (wg-public hub). No-op on every other VM.
#
# WHY THIS EXISTS (2026-08-12)
# ───────────────────────────
# OCI assigns an IPv6 to the VNIC in its CONTROL PLANE. terraform does that
# (c_vps/vps_oci, oci_core_ipv6.analytics_v6 → 2603:c026:c104:8f00:0:c704:63b:6eee)
# and it is genuinely allocated — the terraform apply refreshes it from a real
# OCID. But the GUEST OS never configures it, so nothing on the instance ever
# listens on that address.
#
# Proven, not assumed. Pointing the laptop's wg-public peer at
# [2603:c026:c104:8f00:0:c704:63b:6eee]:51821 and waiting 65s:
#   sent     16.02 KiB -> 16.08 KiB   (packets leaving)
#   received  4.40 KiB ->  4.40 KiB   (nothing coming back)
#   handshake aged out to 1m35s
# Reverted to the IPv4 endpoint and the handshake recovered immediately.
#
# The same missing guest-side IPv6 is why nat64-tayga.nix does not translate:
# its prefix 2603:c026:c104:8f00:ff9b::/96 is carved from a /64 the OS has never
# brought up, so nothing routes to it either. One fix, both features.
#
# WHY RA/DHCPv6 AND NOT A STATIC ADDRESS
# ──────────────────────────────────────
# A static address needs a gateway, and getting an OCI IPv6 gateway wrong
# installs a bad default route on the VM that hosts the wg-public hub — i.e. it
# can cut the fleet off from the machine that fixes it. accept-ra + dhcp6 asks
# the network instead of asserting: if OCI answers, the address and route come
# from the authority that assigned them; if it does not, NOTHING CHANGES and
# IPv4 is untouched. Non-destructive by construction, which matters on a host
# reachable only over the network being edited.
#
# Deployed as a netplan DROP-IN (99-ipv6.yaml), never by editing OCI's own
# 50-cloud-init.yaml: cloud-init rewrites that file on boot and the change would
# silently vanish. Higher-numbered drop-ins merge over lower ones.
{ vmName }:

{ config, lib, pkgs, ... }:

let
  enabled = vmName == "oci-analytics";

  # Primary NIC. OCI Ubuntu images name it ens3 (virtio) — resolved at RUNTIME
  # from the default route rather than hardcoded, because a wrong interface name
  # yields a netplan file that applies cleanly and does nothing at all.
  netplanDropIn = ''
    # Managed by home-manager (ipv6-guest.nix) — do not edit.
    # Drop-in over OCI's cloud-init config; cloud-init rewrites
    # 50-cloud-init.yaml on boot, so IPv6 must live in its own file.
    network:
      version: 2
      ethernets:
        @IFACE@:
          dhcp6: true
          accept-ra: true
  '';
in
lib.mkIf enabled {
  home.packages = with pkgs; [ iproute2 ];

  home.file.".local/share/ipv6-guest/99-ipv6.yaml.tpl".text = netplanDropIn;

  home.activation.installGuestIpv6 = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    trap 'echo "[ipv6-guest] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[ipv6-guest] WARNING: sudo not found — skipping"
      exit 0
    fi

    if [ ! -d /etc/netplan ]; then
      echo "[ipv6-guest] no /etc/netplan — not an Ubuntu/netplan host, skipping"
      exit 0
    fi

    # Interface carrying the default route. Guessing wrong produces a netplan
    # file that applies without error and changes nothing, so resolve it.
    IFACE=$(${pkgs.iproute2}/bin/ip route show default 2>/dev/null | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')
    IFACE=''${IFACE:-ens3}
    echo "[ipv6-guest] primary interface: $IFACE"

    NEW=$(${pkgs.gnused}/bin/sed "s|@IFACE@|$IFACE|" "$HOME/.local/share/ipv6-guest/99-ipv6.yaml.tpl")
    DST=/etc/netplan/99-ipv6.yaml

    CURRENT=""
    $SUDO test -f "$DST" && CURRENT=$($SUDO cat "$DST" 2>/dev/null || true)
    if [ "$NEW" = "$CURRENT" ]; then
      echo "[ipv6-guest] netplan drop-in unchanged — skipping apply"
    else
      printf '%s\n' "$NEW" | $SUDO tee "$DST" > /dev/null
      # netplan refuses world-readable configs (warns and may ignore them).
      $SUDO chmod 600 "$DST"
      # `netplan apply` re-applies ALL configs including OCI's cloud-init one,
      # so a broken drop-in takes IPv4 with it. --no-block so a hung apply can
      # never wedge the deploy; the address also comes up on next boot anyway.
      $SUDO netplan apply 2>&1 | ${pkgs.gnugrep}/bin/grep -v '^$' || true
      echo "[ipv6-guest] applied netplan drop-in for $IFACE"
    fi

    # Report the result so the deploy log says whether it actually worked,
    # rather than leaving it to be discovered by a failing handshake later.
    ${pkgs.coreutils}/bin/sleep 3
    V6=$(${pkgs.iproute2}/bin/ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
         | ${pkgs.gawk}/bin/awk '/inet6/ {print $2; exit}')
    if [ -n "$V6" ]; then
      echo "[ipv6-guest] OK — $IFACE has global IPv6 $V6"
    else
      echo "[ipv6-guest] WARNING: $IFACE still has NO global IPv6." >&2
      echo "[ipv6-guest] OCI may not serve RA/DHCPv6 in this subnet; a static address + gateway would then be required." >&2
    fi
    ) || echo "[ipv6-guest] activation failed; deploy continues"
  '';
}
