# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-mail/src/pilot/container/daemon-network.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — network topology
#
# Network is PERMISSIVE by default — all containers can communicate freely.
# Traffic restrictions are enforced by network-firewall.nix (iptables FORWARD chain),
# not by Docker daemon settings.
#
# Rules:
#   dns   Internal Hickory DNS (10.0.0.1) as primary, Cloudflare (1.1.1.1) as fallback.
#         Read from cloud-data-home-manager.json at nix eval time.
{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ../cloud-data-home-manager.json);
in {
  docker.daemon.settings = {
    dns = [ cloudData.dns.primary cloudData.dns.fallback ];
  };
}
