# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-apps/src/oci-apps.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./pilot/cloud-data-home-manager.json);
  vmData = cloudData.vms."oci-apps";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "oci-apps"; })
    (import ./pilot/shared/httpd.nix {
      sites = {
        cloud-spec = { root = "/opt/containers/cloud-spec"; port = 8099; };
      };
    })
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # VM-specific packages
  home.packages = with pkgs; [ google-cloud-sdk ];
}
