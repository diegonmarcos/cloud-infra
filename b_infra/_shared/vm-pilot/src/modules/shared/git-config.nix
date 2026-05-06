# Shared git configuration for all VMs
# Reads owner info from cloud-data
#
{ config, pkgs, lib, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[.owner]
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    owner = consolidated.owner or {};
  };
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
