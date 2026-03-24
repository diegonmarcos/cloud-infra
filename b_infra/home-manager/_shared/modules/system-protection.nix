# System Protection — Orchestrator
#
# Imports the 3 sub-modules:
#   system-protection-resource-bouncer.nix   — zram, earlyoom, sysctl, cgroups, Docker cap
#   system-protection-watchdog-dropbear.nix  — disk swap, disk watchdog, rescue SSH
#   system-protection-guardrails.nix         — command whitelist/blacklist (imported via shared-all.nix)
#
# Desktop equivalent: unix/aa_nixos-surface_host/src/modules/configuration_resource-bouncer.nix
#
# Usage in VM config:
#   (import ./modules/system-protection.nix { inherit config pkgs lib; ramMB = 1024; })
#   (replaces both old system-protection.nix + rescue-ssh.nix with ONE import)
#
{ config, pkgs, lib, ramMB, rescuePort ? 2200, ... }:

{
  imports = [
    (import ./system-protection-resource-bouncer.nix { inherit config pkgs lib ramMB; })
    (import ./system-protection-watchdog-dropbear.nix { inherit config pkgs lib ramMB rescuePort; })
    # system-protection-guardrails.nix is imported separately via shared-all.nix (always on)
  ];
}
