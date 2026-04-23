# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-gcp-proxy/src/pilot/protection/systemd-control.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# systemd-control.nix — Disable Docker + Ubuntu bloat from systemd
#
# Two categories:
#   1. Docker — container-init.service owns Docker lifecycle
#   2. Ubuntu bloat — fwupd, snapd, unattended-upgrades, release-upgrader
#      These waste 300-400MB RAM on 1GB VMs for features we don't use
#      (nix manages packages, no physical firmware, no in-place OS upgrades)
#
# Runs AFTER all other activations — always has the last word.
{ extraBlacklist ? [] }:

{ config, pkgs, lib, ... }:

let
  # Docker — container-init.sh handles its lifecycle
  dockerBlacklist = [
    "docker.service"
    "docker.socket"
  ];

  # Ubuntu bloat — useless on declaratively-managed cloud VMs
  # fwupd: firmware updater (no physical hardware on VMs) — 176MB RSS
  # snapd: snap package manager (we use nix + docker) — 40MB RSS
  # unattended-upgrades: apt auto-updates (we use nix) — 23MB RSS
  # apt-daily: apt metadata refresh — triggers unattended-upgrades
  # ubuntu-advantage: Ubuntu Pro telemetry
  ubuntuBloatBlacklist = [
    "fwupd.service"
    "fwupd-refresh.timer"
    "unattended-upgrades.service"
    "apt-daily.timer"
    "apt-daily-upgrade.timer"
    "snapd.service"
    "snapd.socket"
    "snapd.seeded.service"
    "snapd.snap-repair.timer"
    "ua-timer.timer"
    "ubuntu-advantage.service"
  ];

  blacklist = dockerBlacklist ++ ubuntuBloatBlacklist ++ extraBlacklist;

  blacklistBash = lib.concatMapStringsSep " " (u: ''"${u}"'') blacklist;

  allActivations = [
    "installContainerInit"
    "configureHickoryDns"
    "systemCleanup"
    "sshdHardening"
    "nixPathEtcEnvironment"
    "sshKeys"
    "authorizedKeys"
    "sharedNodeModules"
    "mcpNodeModulesSymlinks"
    "gitSubmoduleUpdate"
    "noBuildGuard"
    "installResourceBouncer"
    "installWatchdogDropbear"
    "installFirewall"
  ];

in {
  home.activation.systemdControl = lib.hm.dag.entryAfter allActivations ''
    (
    LOG="[systemd-control]"
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    DISABLED=0
    BLACKLIST=(${blacklistBash})
    for unit in "''${BLACKLIST[@]}"; do
      if $SUDO systemctl is-enabled "$unit" >/dev/null 2>&1; then
        # disable only — do NOT use --now (would kill running Docker during HM activation)
        # Docker lifecycle is owned by container-init, which starts it on boot
        $SUDO systemctl disable "$unit" 2>/dev/null
        DISABLED=$((DISABLED + 1))
        echo "$LOG DISABLED: $unit"
      fi
    done
    $SUDO systemctl daemon-reload
    echo "$LOG Done: $DISABLED units disabled (Docker=container-init, Ubuntu bloat=removed)"
    ) || echo "[systemd-control] FAILED — activation continues"
  '';
}
