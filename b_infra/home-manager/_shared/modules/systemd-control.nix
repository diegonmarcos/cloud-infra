# systemd-control.nix — FINAL AUTHORITY over enabled systemd units
#
# This module runs AFTER every other activation.
# It enforces a strict whitelist: only declared units stay enabled.
# Everything else gets disabled.
#
# container-init.service is THE orchestrator for our entire stack.
# Systemd only manages OS boot essentials + container-init.
#
# Usage (in VM nix file):
#   (import ./modules/systemd-control.nix {
#     extraEnabled = [ "google-guest-agent.service" ];  # VM-specific
#     excludeUnits = [ "no-build-guard.service" ];      # e.g. oci-apps
#   })
{ extraEnabled ? [], excludeUnits ? [] }:

{ config, pkgs, lib, ... }:

let
  # ── OS essentials: required for the VM to function ──────────────────
  osServices = [
    "audit-rules.service"
    "auditd.service"
    "chronyd.service"
    "dbus-broker.service"
    "fips-crypto-policy-overlay.service"
    "getty@.service"
    "lvm2-monitor.service"
    "NetworkManager-dispatcher.service"
    "NetworkManager-wait-online.service"
    "NetworkManager.service"
    "rsyslog.service"
    "selinux-autorelabel-mark.service"
    "sshd.service"
    "sssd.service"
    "systemd-confext.service"
    "systemd-network-generator.service"
    "systemd-resolved.service"
    "systemd-sysext.service"
  ];

  osSockets = [
    "dbus.socket"
    "determinate-nixd.socket"
    "dm-event.socket"
    "lvm2-lvmpolld.socket"
    "nix-daemon.socket"
    "pcscd.socket"
    "sssd-kcm.socket"
    "systemd-journald-audit.socket"
    "systemd-userdbd.socket"
  ];

  osTargets = [
    "reboot.target"
    "remote-fs.target"
  ];

  osTimers = [
    "dnf-makecache.timer"
    "fstrim.timer"
    "logrotate.timer"
    "unbound-anchor.timer"
  ];

  # ── Our stack: protection layer + orchestrator ──────────────────────
  customServices = [
    "container-init.service"   # THE orchestrator — starts everything
    "docker.service"           # daemon — container-init depends on it
    "earlyoom.service"         # OOM protection — must run before Docker
    "firewall.service"         # nftables — must run before Docker
    "rescue-ssh.service"       # Dropbear — untouchable rescue access
    "watchdog-petter.service"  # kernel watchdog
    "disk-swap.service"        # swap setup — before Docker
    "zram-setup.service"       # compressed swap — before Docker
    "no-build-guard.service"   # removes build tools on boot
  ];

  customTimers = [
    "authelia-backup.timer"
    "disk-watchdog.timer"
    "vaultwarden-backup.timer"
  ];

  # ── Combine all whitelisted units ───────────────────────────────────
  allWhitelisted = lib.unique (
    osServices ++ osSockets ++ osTargets ++ osTimers
    ++ customServices ++ customTimers
    ++ extraEnabled
  );

  # Remove excluded units
  whitelist = builtins.filter (u: !(builtins.elem u excludeUnits)) allWhitelisted;

  # Build the whitelist as a bash associative array for O(1) lookup
  whitelistBash = lib.concatMapStringsSep "\n" (u: ''  [${u}]=1'') whitelist;

  # Activation names present on ALL VMs (from shared-all.nix + system-protection + firewall)
  # This module depends on ALL of them to guarantee it runs LAST.
  # DO NOT add VM-specific activations here (e.g. installGcpAgent, installIdleScripts)
  allActivations = [
    # shared-all.nix imports
    "installContainerInit"
    "dockerService"
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
    # system-protection.nix (parameterized, imported by all VMs)
    "installResourceBouncer"
    "installWatchdogDropbear"
    # firewall.nix (parameterized, imported by all VMs)
    "installFirewall"
  ];

in {
  home.file.".local/share/systemd-control/whitelist.txt".text =
    lib.concatStringsSep "\n" whitelist + "\n";

  home.activation.systemdControl = lib.hm.dag.entryAfter allActivations ''
    (
    trap 'echo "[systemd-control] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    LOG="[systemd-control]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$LOG WARNING: sudo not found — skipping"
      exit 0
    fi

    echo "$LOG ═══ SYSTEMD CONTROL — FINAL AUTHORITY ═══"

    # ── Build whitelist lookup ────────────────────────────────────────
    declare -A WHITELIST=(
    ${whitelistBash}
    )

    # ── Phase 1: Ensure all whitelisted units are enabled ─────────────
    ENABLED=0
    for unit in "''${!WHITELIST[@]}"; do
      # Skip template units (getty@.service) — can't enable directly
      [[ "$unit" == *"@."* ]] && continue

      # Check if unit file exists before trying to enable
      if $SUDO systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
        if ! $SUDO systemctl is-enabled "$unit" >/dev/null 2>&1; then
          $SUDO systemctl enable "$unit" 2>/dev/null && ENABLED=$((ENABLED + 1))
        fi
      fi
    done
    [ "$ENABLED" -gt 0 ] && echo "$LOG Enabled $ENABLED units"

    # ── Phase 2: Disable non-whitelisted enabled units ────────────────
    DISABLED=0
    DISABLED_LIST=""

    # Get all currently enabled units (services, sockets, timers, targets)
    while IFS= read -r line; do
      unit=$(echo "$line" | awk '{print $1}')

      # Skip empty lines, headers, template units
      [ -z "$unit" ] && continue
      [[ "$unit" == "UNIT" ]] && continue
      [[ "$unit" == *"@."* ]] && continue

      # If not in whitelist → disable
      if [ -z "''${WHITELIST[$unit]+x}" ]; then
        $SUDO systemctl disable "$unit" 2>/dev/null && {
          DISABLED=$((DISABLED + 1))
          DISABLED_LIST="$DISABLED_LIST $unit"
        }
      fi
    done < <($SUDO systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null)

    if [ "$DISABLED" -gt 0 ]; then
      echo "$LOG Disabled $DISABLED non-whitelisted units:$DISABLED_LIST"
    fi

    $SUDO systemctl daemon-reload

    echo "$LOG Whitelist: ''${#WHITELIST[@]} units | Enabled: +$ENABLED | Disabled: -$DISABLED"
    echo "$LOG ═══ SYSTEMD CONTROL COMPLETE ═══"
    ) || echo "[systemd-control] FAILED — see errors above, activation continues"
  '';
}
