# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-analytics/src/pilot/protection/system-protection.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Orchestrator
#
# Reads VM specs from cloud-data-home-manager.json (ram_gb, rescue_port)
# Imports sub-modules with derived parameters.
#
# Usage: (import ./protection/system-protection.nix { inherit config pkgs lib; vmName = "gcp-proxy"; })
{ config, pkgs, lib, vmName, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ../cloud-data-home-manager.json);
  vmData = cloudData.vms.${vmName};
  ramMB = vmData.specs.ram_gb * 1024;
  cpus = vmData.specs.cpu;
  rescuePort = vmData.rescue_port;
  userName = vmData.user;
  userId = 1000;
in {
  imports = [
    (import ./resource-bouncer.nix { inherit config pkgs lib ramMB; })
    (import ./watchdog.nix { inherit config pkgs lib ramMB; })
    (import ./rescue-ssh.nix { inherit config pkgs lib rescuePort; })
    (import ./scheduler.nix { inherit config pkgs lib ramMB; })
    (import ./layer2-identity.nix { inherit config pkgs lib ramMB cpus userName userId; })
    (import ../dashboard/dashboard.nix { inherit vmName; })
    (import ../agents/health-agent.nix { inherit config pkgs lib; })
    # guardrails.nix disabled (POSIX sh bug)
    # no-build-guard.nix imported by default.nix directly
  ];
}
