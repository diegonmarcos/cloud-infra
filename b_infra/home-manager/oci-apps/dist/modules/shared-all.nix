# Auto-import all non-parameterized shared modules
# Parameterized modules (firewall, system-protection, idle-shutdown,
# resource-bouncer, httpd) must be imported explicitly with their args.
{ imports = [
    ./authorized-keys.nix
    ./container-tools.nix
    ./dns-hickory.nix
    ./docker-service.nix
    ./guardrails.nix
    ./ssh-keys.nix
    ./shell-path.nix
    ./sshd-hardening.nix
    ./system-cleanup.nix
  ];
}
