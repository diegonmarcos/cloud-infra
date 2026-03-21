# Fully declarative iptables — owns ALL chains (INPUT, FORWARD, NAT)
#
# Docker runs with iptables:false (daemon.json) — we manage everything.
# Port publishing works via docker-proxy (userland), no DNAT needed.
# We handle: INPUT filtering, FORWARD for bridges, MASQUERADE for outbound.
#
# Docker subnet range: 172.16.0.0/12 (covers 172.16-31.x.x)
# WG subnet: 10.0.0.0/24
#
# Usage in VM config:
#   (import ./modules/firewall.nix {
#     vmName = "oci-apps";
#     publicPorts = [
#       { port = 8081; proto = "tcp"; desc = "C3 API"; }
#     ];
#   })
#
{ vmName, publicPorts ? [] }:

{ config, lib, pkgs, ... }:

let
  dockerSubnet = "172.16.0.0/12";
  wgSubnet = "10.0.0.0/24";

  # Build iptables ACCEPT rules for public ports (INPUT chain)
  mkPortRule = r:
    let
      port = toString r.port;
      proto = r.proto or "tcp";
      comment = r.desc or "port-${port}";
    in
      "iptables -A INPUT -p ${proto} --dport ${port} -m comment --comment \"${comment}\" -j ACCEPT";

  portRules = builtins.concatStringsSep "\n    " (map mkPortRule publicPorts);

  fwScript = ''
    #!/bin/bash
    # Managed by home-manager (firewall.nix) — do not edit
    # VM: ${vmName} — fully declarative iptables (Docker iptables: false)
    set -euo pipefail
    export PATH="${pkgs.iptables}/bin:$PATH"

    # ══════════════════════════════════════════════════════════════
    # FILTER TABLE
    # ══════════════════════════════════════════════════════════════

    # ── INPUT chain ──
    iptables -F INPUT 2>/dev/null || true
    iptables -P INPUT DROP

    # Loopback
    iptables -A INPUT -i lo -j ACCEPT
    # Established/related
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # ICMP
    iptables -A INPUT -p icmp -j ACCEPT
    # WireGuard interface (all VPN traffic trusted)
    iptables -A INPUT -i wg0 -j ACCEPT
    # SSH
    iptables -A INPUT -p tcp --dport 22 -m comment --comment "SSH" -j ACCEPT
    # WireGuard port
    iptables -A INPUT -p udp --dport 51820 -m comment --comment "WireGuard" -j ACCEPT
    # VM-specific public ports (static from nix — fallback)
    ${portRules}

    # Dynamic ports from cloud-data-firewall-rules.json (cloud-data pipeline)
    FW_JSON="/opt/containers/cloud-data/cloud-data-firewall-rules.json"
    if [ -f "$FW_JSON" ] && command -v jq >/dev/null 2>&1; then
      DYNAMIC_PORTS=$(jq -r --arg vm "${vmName}" '.vms[$vm].ingress[]? | "\(.port):\(.proto // "tcp"):\(.service // "dynamic")"' "$FW_JSON" 2>/dev/null || true)
      for entry in $DYNAMIC_PORTS; do
        PORT=''${entry%%:*}
        REST=''${entry#*:}
        PROTO=''${REST%%:*}
        SVC=''${REST#*:}
        iptables -C INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT 2>/dev/null || \
          iptables -A INPUT -p "$PROTO" --dport "$PORT" -m comment --comment "$SVC (dynamic)" -j ACCEPT
      done
      echo "[firewall] Applied dynamic ports from $FW_JSON"
    fi

    # ── FORWARD chain ──
    # Docker with iptables:false doesn't manage FORWARD — we do.
    iptables -F FORWARD 2>/dev/null || true
    iptables -P FORWARD DROP

    # Established/related forwarded connections
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Docker containers → internet (outbound)
    iptables -A FORWARD -s ${dockerSubnet} ! -d ${dockerSubnet} -j ACCEPT
    # Inter-container traffic (same or cross bridge)
    iptables -A FORWARD -s ${dockerSubnet} -d ${dockerSubnet} -j ACCEPT
    # Internet → Docker containers (return traffic for docker-proxy, handled by ESTABLISHED above)
    # WireGuard forwarding (cross-VM traffic)
    iptables -A FORWARD -i wg0 -j ACCEPT
    iptables -A FORWARD -o wg0 -j ACCEPT

    # ══════════════════════════════════════════════════════════════
    # NAT TABLE
    # ══════════════════════════════════════════════════════════════

    iptables -t nat -F POSTROUTING 2>/dev/null || true

    # MASQUERADE: Docker containers reaching internet
    iptables -t nat -A POSTROUTING -s ${dockerSubnet} ! -d ${dockerSubnet} -j MASQUERADE
    # MASQUERADE: WireGuard traffic
    iptables -t nat -A POSTROUTING -s ${wgSubnet} -o eth0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s ${wgSubnet} -o ens4 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s ${wgSubnet} ! -d ${wgSubnet} -j MASQUERADE

    # ══════════════════════════════════════════════════════════════
    # NFTABLES RAW — whitelist WireGuard before Docker's isolation
    # ══════════════════════════════════════════════════════════════
    # Docker creates nft raw PREROUTING rules that DROP traffic to
    # container IPs from non-bridge interfaces. This blocks WG traffic
    # (iifname=wg0) to published ports (993, 465, etc.) even though
    # iptables INPUT accepts wg0. Fix: insert ACCEPT for wg0 first.
    if command -v nft >/dev/null 2>&1 && nft list table ip raw >/dev/null 2>&1; then
      # Remove any existing wg0 rule to avoid duplicates
      nft -a list chain ip raw PREROUTING 2>/dev/null | grep 'iifname "wg0"' | awk '{print $NF}' | while read handle; do
        nft delete rule ip raw PREROUTING handle "$handle" 2>/dev/null || true
      done
      # Insert at top — before Docker's container isolation drops
      nft insert rule ip raw PREROUTING iifname wg0 accept
      echo "[firewall] nft raw: wg0 whitelisted in PREROUTING"
    fi

    echo "[firewall] Applied: full declarative iptables for ${vmName} (${toString (builtins.length publicPorts)} public ports)"
  '';

in {
  home.packages = [ pkgs.iptables ];

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
    (
    trap 'echo "[firewall] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
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
    ) || echo "[firewall] FAILED — see errors above, activation continues"
  '';
}
