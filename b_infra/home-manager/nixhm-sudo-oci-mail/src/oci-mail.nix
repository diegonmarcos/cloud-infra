{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./pilot/cloud-data-home-manager.json);
  vmData = cloudData.vms."oci-mail";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "oci-mail"; })
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # VM-specific packages
  home.packages = with pkgs; [ swaks ];

  # VM-specific aliases (mail tools)
  programs.bash.shellAliases = {
    mailogs = "docker logs -f mailu-front-1";
    mailqueue = "docker exec -it mailu-smtp-1 postqueue -p";
  };
}
