# System Protection — Orchestrator
#
# Reads VM specs from _cloud-data-consolidated.json[._home_manager.vms] (ram_gb, rescue_port)
# 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
# Imports sub-modules with derived parameters.
#
# Usage in VM config:
#   (import ./modules/system-protection.nix { inherit config pkgs lib; vmName = "gcp-proxy"; })
{ config, pkgs, lib, vmName, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ./_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
  };
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
    (import ./system-protection-disk-ballast.nix { inherit config pkgs lib; })
    (import ./system-protection-scheduler-fifo-rr-cfs.nix { inherit config pkgs lib ramMB; })
    (import ./system-protection-layer2-identity.nix { inherit config pkgs lib ramMB cpus userName userId; })
    (import ./system-protection-dashboard.nix { inherit vmName; })
    # system-protection-guardrails.nix + system-protection-no-build-guard.nix via shared-all.nix
  ];
}
