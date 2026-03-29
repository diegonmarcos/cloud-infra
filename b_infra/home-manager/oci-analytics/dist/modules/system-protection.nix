# System Protection — Orchestrator
#
# Reads VM specs from cloud-data-home-manager.json (ram_gb, rescue_port)
# Imports sub-modules with derived parameters.
#
# Usage in VM config:
#   (import ./modules/system-protection.nix { inherit config pkgs lib; vmName = "gcp-proxy"; })
{ config, pkgs, lib, vmName, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
  vmData = cloudData.vms.${vmName};
  ramMB = vmData.specs.ram_gb * 1024;
  cpus = vmData.specs.cpu;
  rescuePort = vmData.rescue_port;
  userName = vmData.user;
  userId = 1000;
in {
  imports = [
    (import ./system-protection-resource-bouncer.nix { inherit config pkgs lib ramMB; })
    (import ./system-protection-watchdog-petter-dropbear-health-agent.nix { inherit config pkgs lib ramMB rescuePort; })
    (import ./system-protection-scheduler-fifo-rr-cfs.nix { inherit config pkgs lib ramMB; })
    (import ./system-protection-layer2-identity.nix { inherit config pkgs lib ramMB cpus userName userId; })
    # system-protection-guardrails.nix + system-protection-no-build-guard.nix via shared-all.nix
  ];
}
