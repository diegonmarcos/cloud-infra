# Auto-import all non-parameterized shared modules
# Parameterized modules (firewall, system-protection, idle-shutdown,
# httpd) must be imported explicitly with their args.
{ imports = [
    ./authorized-keys.nix
    ./container-tools.nix
    ./dns-hickory.nix
    ./docker-service.nix
    ./system-protection-guardrails.nix
    ./node-npm-deps.nix
    ./ssh-keys.nix
    ./shell-path.nix
    ./sshd-hardening.nix
    ./system-cleanup.nix
    ./no-build-guard.nix
  ];
}
