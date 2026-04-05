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
