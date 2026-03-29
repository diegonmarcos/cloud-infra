# Auto-import all non-parameterized shared modules
# Parameterized modules (network-firewall, system-protection, infra-idle-shutdown,
# httpd, system-protection-systemd-control) must be imported explicitly with their args.
{ imports = [
    # container
    ./container.nix
    # infra (infra-managed-header.nix is a utility, imported explicitly by modules that need it)
    ./infra-shell-path.nix
    ./infra-system-cleanup.nix
    # network
    ./network-dns-hickory.nix
    # node
    ./node-npm-deps.nix
    # security
    ./security-authorized-keys.nix
    ./security-ssh-keys.nix
    ./security-sshd-hardening.nix
    # system-protection
    ./system-protection-guardrails.nix
    ./system-protection-no-build-guard.nix
    # docker ops
    ./docker-pull-up.nix
    # observability
    ./health-post-logs.nix
  ];
}
