# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-mail/src/pilot/shared/git-config.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Shared git configuration for all VMs
# Reads owner info from cloud-data
#
{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ../cloud-data-home-manager.json);
in {
  programs.git = {
    enable = true;
    userName = cloudData.owner.name;
    userEmail = cloudData.owner.email;
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };
}
