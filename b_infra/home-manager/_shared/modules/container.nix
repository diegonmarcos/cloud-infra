# Container Control — orchestrator for all container-related modules
{ imports = [
    ./container-control-init.nix
    ./container-control-tools.nix
    ./container-control-no-build-guardrails.nix
  ];
}
