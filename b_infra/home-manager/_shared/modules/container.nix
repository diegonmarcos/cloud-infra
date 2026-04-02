# Container Control — orchestrator for all container-related modules
# NOTE: container-control-init.nix is parameterized (needs vmName) —
# imported explicitly by each VM config, NOT here.
{ imports = [
    ./container-control-daemon.nix
    ./container-control-tools.nix
    ./container-control-no-build-guardrails.nix
    ./packages-from-json.nix
  ];
}
