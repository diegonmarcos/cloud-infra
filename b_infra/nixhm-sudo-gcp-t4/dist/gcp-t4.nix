# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-gcp-t4/src/gcp-t4.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager + .home_manager]
  consolidated = builtins.fromJSON (builtins.readFile ./pilot/_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    home_manager = consolidated.home_manager or { state_version = "24.11"; };
  };
  vmData = cloudData.vms."gcp-t4";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "gcp-t4"; })
    # VM-specific: auto-shutdown after 1h idle (GPU spot instance)
    (import ./pilot/infra/idle-shutdown.nix { inherit config pkgs lib; vmName = "gcp-t4"; })
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # VM-specific aliases (GPU monitoring)
  programs.bash.shellAliases = {
    gsmi = "docker exec ollama nvidia-smi";
    ollama-models = "docker exec ollama ollama list";
    ollama-pull = "docker exec ollama ollama pull";
  };
}
