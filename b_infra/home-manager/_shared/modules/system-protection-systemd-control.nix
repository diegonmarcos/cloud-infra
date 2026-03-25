# systemd-control.nix — Disable Docker from systemd auto-start
#
# container-init.service owns the Docker lifecycle.
# This module ensures Docker never auto-starts via systemd.
# All other services (rescue-ssh, watchdog, earlyoom, etc.) stay systemd-managed.
#
# Runs AFTER all other activations — always has the last word.
{ extraBlacklist ? [] }:

{ config, pkgs, lib, ... }:

let
  # ONLY Docker — container-init.sh handles its lifecycle
  blacklist = [
    "docker.service"
    "docker.socket"
  ] ++ extraBlacklist;

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

    BLACKLIST=(${blacklistBash})
    for unit in "''${BLACKLIST[@]}"; do
      if $SUDO systemctl is-enabled "$unit" >/dev/null 2>&1; then
        $SUDO systemctl disable "$unit" 2>/dev/null
        echo "$LOG DISABLED: $unit (owned by container-init)"
      fi
    done
    $SUDO systemctl daemon-reload
    echo "$LOG Docker disabled from auto-start — container-init.service owns it"
    ) || echo "[systemd-control] FAILED — activation continues"
  '';
}
