{ config, pkgs, lib, ... }:

let
  cloudData = builtins.fromJSON (builtins.readFile ./pilot/cloud-data-home-manager.json);
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
