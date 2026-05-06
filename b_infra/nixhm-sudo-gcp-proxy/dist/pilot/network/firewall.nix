# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-gcp-proxy/src/pilot/network/firewall.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Fully declarative iptables + nftables — owns ALL chains
#
# This firewall is THE SINGLE OWNER of all packet filtering rules.
# Docker runs with iptables:false (daemon.json) — it creates NO rules.
# All containers use network_mode: host — no DNAT, no bridge isolation.
#
# On every run: flush ALL tables → rebuild from scratch. Zero stale rules.
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
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[.native.docker + .native.wireguard]
  # 2026-04-27 migrated: cloud-data-firewall-rules.json → _cloud-data-consolidated.json[.firewalls.os.<vm>]
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    docker = consolidated.native.docker or {};
    wireguard = consolidated.native.wireguard or {};
  };
  dockerSubnet = cloudData.docker.subnet;
  wgSubnet = cloudData.wireguard.subnet;

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
    # VM: ${vmName} — fully declarative iptables + nftables
    # THIS SCRIPT OWNS ALL PACKET FILTERING. Docker creates nothing.
    set -euo pipefail
    export PATH="${pkgs.iptables}/bin:$PATH"

    # ══════════════════════════════════════════════════════════════
    # PHASE 0: FLUSH EVERYTHING — clean slate
    # ══════════════════════════════════════════════════════════════

    # Filter table
    iptables -F INPUT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true

    # NAT table — ALL chains (kills any zombie Docker DNAT/SNAT rules)
    iptables -t nat -F 2>/dev/null || true

    # Mangle table
    iptables -t mangle -F 2>/dev/null || true

    # nftables raw table — flush Docker's container isolation rules
    if command -v nft >/dev/null 2>&1 && nft list table ip raw >/dev/null 2>&1; then
      nft flush chain ip raw PREROUTING 2>/dev/null || true
      nft flush chain ip raw OUTPUT 2>/dev/null || true
      echo "[firewall] nft raw: flushed all rules"
    fi

    # ══════════════════════════════════════════════════════════════
    # PHASE 1: FILTER TABLE — INPUT
    # ══════════════════════════════════════════════════════════════

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
    iptables -A INPUT -p udp --dport ${toString cloudData.wireguard.port} -m comment --comment "WireGuard" -j ACCEPT
    # VM-specific public ports (static from nix)
    ${portRules}

    # Dynamic ports from _cloud-data-consolidated.json[.firewalls.os.<vm>]
    # Path-priority chain: in-image bundle > runtime deploy dir > legacy clone
    FW_JSON=""
    for _p in \
      /app/_cloud-data-consolidated.json \
      /opt/containers/cloud-data/_cloud-data-consolidated.json \
      "$HOME/git/cloud/2_configs/dist/_cloud-data-consolidated.json" \
      "$HOME/git/cloud/cloud-data/_cloud-data-consolidated.json"; do
      [ -f "$_p" ] && FW_JSON="$_p" && break
    done
    if [ -n "$FW_JSON" ] && [ -f "$FW_JSON" ] && command -v jq >/dev/null 2>&1; then
      DYNAMIC_PORTS=$(jq -r --arg vm "${vmName}" '.firewalls.os[$vm][]? | "\(.port):\(.proto // "tcp"):\(.owned_by // .desc // "dynamic")"' "$FW_JSON" 2>/dev/null || true)
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

    # ══════════════════════════════════════════════════════════════
    # PHASE 2: FILTER TABLE — FORWARD
    # ══════════════════════════════════════════════════════════════

    iptables -P FORWARD DROP

    # Established/related
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Docker containers → internet (outbound)
    iptables -A FORWARD -s ${dockerSubnet} ! -d ${dockerSubnet} -j ACCEPT
    # Inter-container traffic
    iptables -A FORWARD -s ${dockerSubnet} -d ${dockerSubnet} -j ACCEPT
    # WireGuard forwarding
    iptables -A FORWARD -i wg0 -j ACCEPT
    iptables -A FORWARD -o wg0 -j ACCEPT

    # ══════════════════════════════════════════════════════════════
    # PHASE 3: NAT TABLE — MASQUERADE only, zero DNAT
    # ══════════════════════════════════════════════════════════════
    # With network_mode: host, services bind directly on 0.0.0.0.
    # No DNAT needed. No docker-proxy. No port mapping.
    # Only MASQUERADE for outbound from Docker bridges and WG.

    iptables -t nat -A POSTROUTING -s ${dockerSubnet} ! -d ${dockerSubnet} -j MASQUERADE
    iptables -t nat -A POSTROUTING -s ${wgSubnet} -o eth0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s ${wgSubnet} -o ens4 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s ${wgSubnet} ! -d ${wgSubnet} -j MASQUERADE

    echo "[firewall] Applied: fully declarative iptables + nft for ${vmName} (${toString (builtins.length publicPorts)} static ports)"
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
