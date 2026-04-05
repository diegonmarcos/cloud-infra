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
