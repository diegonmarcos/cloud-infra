{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./pilot/cloud-data-home-manager.json);
  vmData = cloudData.vms."oci-analytics";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "oci-analytics"; })
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # VM-specific aliases (analytics tools)
  programs.bash.shellAliases = {
    wmlogs = "docker logs -f windmill-server";
    wmworker = "docker logs -f windmill-worker";
  };
}
