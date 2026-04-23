# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-gcp-t4/src/pilot/container/daemon-security.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — process isolation & security hardening
#
# Rules:
#   no-new-privileges  Containers cannot gain additional privileges via setuid/setgid
#   userland-proxy     Disabled — forces kernel-level port forwarding only,
#                      no userland TCP proxy that could bypass firewall rules
#   live-restore       Containers survive daemon restarts (upgrades, crashes)
#   log caps           10MB × 3 files per container — prevents disk exhaustion
#   ulimits            File descriptor cap at 65536 (soft + hard)
{ config, pkgs, lib, ... }:

{
  docker.daemon.settings = {
    no-new-privileges = true;
    userland-proxy = false;
    live-restore = true;

    log-driver = "json-file";
    log-opts = {
      max-size = "10m";
      max-file = "3";
    };

    default-ulimits = {
      nofile = {
        Name = "nofile";
        Hard = 65536;
        Soft = 65536;
      };
    };
  };
}
