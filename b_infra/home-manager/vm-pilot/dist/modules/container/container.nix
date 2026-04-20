# Container Control — orchestrator for all container-related modules
# NOTE: container-control-init.nix is parameterized (needs vmName) —
# imported explicitly by each VM config, NOT here.
{ imports = [
    ./daemon.nix
    ./tools.nix
    # no-build-guardrails.nix moved to default.nix — conditionally excluded for oci-apps (ARM 24GB can build)
    # Phase 1 disabled — nix eval fails in GHA dist context. Debug locally first.
    # ./packages-from-json.nix
  ];
}
