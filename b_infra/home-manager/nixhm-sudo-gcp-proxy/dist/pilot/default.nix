# vm-pilot: Single entry point for all shared VM modules
# Usage: (import ./modules/default.nix { vmName = "oci-apps"; })
#
# Consolidates 37+ modules into a single import.
# Per-VM differences are driven by cloud-data JSON, parameterized by vmName.
#
{ vmName }:
{ config, pkgs, lib, ... }:
let
  cloudData = builtins.fromJSON (builtins.readFile ./cloud-data-home-manager.json);
  vmData = cloudData.vms.${vmName};
  publicPorts = map (p: { port = p.port; proto = p.proto; desc = p.desc; }) vmData.public_ports
    ++ [{ port = vmData.rescue_port; proto = "tcp"; desc = "Rescue SSH (Dropbear)"; }];
in {
  imports = [
    # ── Protection (system-protection orchestrator imports: resource-bouncer,
    #    watchdog, rescue-ssh, scheduler, layer2-identity, dashboard, health-agent)
    (import ./protection/system-protection.nix { inherit config pkgs lib; inherit vmName; })
    (import ./protection/systemd-control.nix {})
  ] ++ lib.optionals (vmName != "oci-apps") [
    ./protection/no-build-guard.nix  # oci-apps (ARM 24GB) can build — all others are E2 Micro
  ] ++ [
    # ./protection/guardrails.nix  # DISABLED — POSIX sh two-word subcommand bug

    # ── Container (container orchestrator imports: daemon, tools, no-build-guardrails)
    (import ./container/init.nix { inherit vmName; })
    ./container/container.nix

    # ── Network
    (import ./network/wireguard.nix { inherit vmName; })
    (import ./network/firewall.nix { inherit vmName; inherit publicPorts; })
    ./network/dns-hickory.nix

    # ── Security
    ./security/ssh-keys.nix
    ./security/authorized-keys.nix
    ./security/sshd-hardening.nix
    ./security/serial-console.nix

    # ── Infra
    ./infra/shell-path.nix
    ./infra/system-cleanup.nix

    # ── Packages
    ./packages/node-npm-deps.nix
    ./packages/docker-pull-up.nix

    # ── Agents (new in vm-pilot)
    ./agents/journal-ntfy.nix
    ./agents/data-publisher.nix
    ./agents/evidence-collector.nix

    # ── Shared user config
    (import ./shared/bash-config.nix { inherit vmName; })
    ./shared/git-config.nix
  ];
}
