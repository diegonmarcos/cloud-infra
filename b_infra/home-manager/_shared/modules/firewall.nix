# OS-level firewall (iptables) — defense-in-depth behind cloud provider firewalls
#
# Default policy: DROP all incoming on public interfaces
# Always allowed: SSH (22), WireGuard (51820), ICMP, established connections
# WG-bound services (10.0.0.x:*) don't need rules — wg0 is fully accepted
#
# Usage in VM config:
#   (import ./modules/firewall.nix {
#     vmName = "oci-apps";
#     publicPorts = [
#       { port = 8081; proto = "tcp"; desc = "C3 API"; }
#       { port = 3010; proto = "tcp"; desc = "AFFiNE"; }
#     ];
#   })
#
{ vmName, publicPorts ? [] }:

{ config, lib, pkgs, ... }:

let
  # Build iptables ACCEPT rules for public ports
  mkPortRule = r:
    let
      port = toString r.port;
      proto = r.proto or "tcp";
      comment = r.desc or "port-${port}";
    in
      "iptables -A INPUT -p ${proto} --dport ${port} -m comment --comment \"${comment}\" -j ACCEPT";

  portRules = builtins.concatStringsSep "\n    " (map mkPortRule publicPorts);

  # Generate the full iptables script
  fwScript = ''
    #!/bin/bash
    # Managed by home-manager (firewall.nix) — do not edit
    # VM: ${vmName} — ${toString (builtins.length publicPorts)} public port rules
    set -euo pipefail

    # Flush existing INPUT rules (keep Docker/FORWARD intact)
    iptables -F INPUT 2>/dev/null || true

    # Default policy: DROP incoming
    iptables -P INPUT DROP

    # Always accept: loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Always accept: established/related connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Always accept: ICMP (ping)
    iptables -A INPUT -p icmp -j ACCEPT

    # Always accept: WireGuard interface (all traffic over VPN is trusted)
    iptables -A INPUT -i wg0 -j ACCEPT

    # Always accept: SSH (before DROP policy takes effect)
    iptables -A INPUT -p tcp --dport 22 -m comment --comment "SSH" -j ACCEPT

    # Always accept: WireGuard port (UDP)
    iptables -A INPUT -p udp --dport 51820 -m comment --comment "WireGuard" -j ACCEPT

    # VM-specific public ports
    ${portRules}

    echo "[firewall] Applied: DROP policy + ${toString (builtins.length publicPorts)} public ports for ${vmName}"
  '';

in {
  home.file.".local/share/firewall/firewall.sh" = {
    executable = true;
    text = fwScript;
  };

  home.file.".local/share/firewall/firewall.service".text = ''
    [Unit]
    Description=OS-level firewall (${vmName})
    After=network-pre.target
    Before=network.target docker.service wg-quick@wg0.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/firewall.sh

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installFirewall = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[firewall] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/firewall"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/firewall.sh" /opt/scripts/firewall.sh
    $SUDO chmod +x /opt/scripts/firewall.sh
    $SUDO cp -f "$SRC/firewall.service" /etc/systemd/system/firewall.service

    # Diff check — only restart if changed
    CURRENT=""
    if $SUDO test -f /opt/scripts/.firewall.sh.prev; then
      CURRENT=$($SUDO cat /opt/scripts/.firewall.sh.prev 2>/dev/null || true)
    fi
    NEW=$($SUDO cat /opt/scripts/firewall.sh)

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable firewall.service 2>/dev/null || true

    if [ "$NEW" = "$CURRENT" ]; then
      echo "[firewall] rules unchanged — skipping"
    else
      $SUDO /opt/scripts/firewall.sh
      echo "$NEW" | $SUDO tee /opt/scripts/.firewall.sh.prev > /dev/null
      echo "[firewall] rules applied for ${vmName}"
    fi
  '';
}
