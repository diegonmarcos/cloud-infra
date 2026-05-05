# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-analytics/src/pilot/default.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# vm-pilot: Single entry point for all shared VM modules
# Usage: (import ./modules/default.nix { vmName = "oci-apps"; })
#
# Consolidates 37+ modules into a single import.
# Per-VM differences are driven by cloud-data JSON, parameterized by vmName.
#
{ vmName }:
{ config, pkgs, lib, ... }:
let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
  consolidated = builtins.fromJSON (builtins.readFile ./_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
  };
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
    ./protection/no-build-guard.nix        # WARNING: small VM — remind operators not to build
    ./container/no-build-guardrails.nix    # WARNING: docker wrapper — warns on build/--build
  ] ++ [
    # ── Container (container orchestrator imports: daemon, tools)
    (import ./container/init.nix { inherit vmName; })
    ./container/container.nix

    # ── Network
    (import ./network/wireguard.nix { inherit vmName; })
    (import ./network/firewall.nix { inherit vmName; inherit publicPorts; })
    ./network/dns-hickory.nix
    ./network/etc-hosts-clean.nix    # strips *.diegonmarcos.com hijacks (Caddy = sole route owner)

    # ── Security
    ./security/ssh-keys.nix
    ./security/authorized-keys.nix
    (import ./security/sshd-hardening.nix { inherit vmName; })
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
    ./agents/log-shipper.nix

    # ── Shared user config
    (import ./shared/bash-config.nix { inherit vmName; })
    ./shared/git-config.nix
  ];
}
