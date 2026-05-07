# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/nixhm-sudo-oci-apps/src/pilot/infra/prune-maintenance.nix
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Infra Prune Maintenance — daily proactive cleanup of docker + nix + journald
#
# WHY this exists
# ───────────────
# protection/watchdog-petter-dropbear-health-agent.nix has a disk-watchdog
# that ONLY fires above 85% / 90% / 95% thresholds. Below those, prunables
# accumulate freely (build cache, untagged images, stopped containers, old
# nix generations, journald logs). On VMs that stay comfortably under the
# WARN line for months, that's many GB of dead weight.
#
# This module mirrors the desktop's storage-maintenance.service pattern
# (unix/aa_nixos-surface_host/src/modules/configuration_system-protection-storage.nix):
# scheduled, low-priority, conservative defaults.
#
# WHAT IT RUNS (all safe — no data-loss ops)
#   docker container prune -f                       drop stopped containers
#   docker image prune -f --filter until=72h        drop dangling images >72h
#   docker builder prune -f --keep-storage=1G       cap build cache at 1G
#   journalctl --vacuum-time=14d --vacuum-size=200M cap journals
#   nix-collect-garbage --delete-older-than 7d      drop hm gens >7d
#   nix-store --optimise                            retroactive hardlink dedup
#
# WHAT IT DOES NOT RUN (intentionally — guardrail-banned in protection/guardrails.nix)
#   docker volume prune              — may contain databases
#   docker system prune -a --volumes — same
#   docker image prune -af           — drops images currently unused but
#                                      possibly needed for next deploy
#
# Schedule: daily 03:30 (staggered 30min before disk-swap-maintenance at
# 04:00 to avoid IO contention on E2 Micros).
#
# Imported by: ./default.nix (parameterless — every VM gets it).
{ config, pkgs, lib, ... }:

{
  home.file.".local/share/system-protection/infra-prune-maintenance.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Don't `set -e` — every prune op is independent; a single failure
      # (e.g. docker daemon down, nix-collect-garbage missing) must not
      # abort the rest of the run.
      set -u

      LOG_PREFIX="[prune-maint]"

      echo "$LOG_PREFIX === $(date '+%Y-%m-%d %H:%M:%S') ==="

      # ── Disk before ──────────────────────────────────────────────────
      USAGE_BEFORE=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
      AVAIL_BEFORE_KB=$(df -P / | awk 'NR==2 { print $4 }')
      echo "$LOG_PREFIX Disk before: ''${USAGE_BEFORE}% used, $((AVAIL_BEFORE_KB/1024))MB free"

      # ── Docker pruning (skip cleanly if daemon down) ─────────────────
      if command -v docker >/dev/null 2>&1 && \
         docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then

        DOCKER_BEFORE=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null \
          | awk '{print $0}' | tr '\n' '|' || echo "?")
        echo "$LOG_PREFIX Docker before: $DOCKER_BEFORE"

        docker container prune -f 2>&1 | sed "s/^/$LOG_PREFIX docker-container: /"
        docker image prune -f --filter "until=72h" 2>&1 | sed "s/^/$LOG_PREFIX docker-image: /"
        docker builder prune -f --keep-storage=1G 2>&1 | sed "s/^/$LOG_PREFIX docker-builder: /"

        DOCKER_AFTER=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null \
          | awk '{print $0}' | tr '\n' '|' || echo "?")
        echo "$LOG_PREFIX Docker after : $DOCKER_AFTER"
      else
        echo "$LOG_PREFIX Docker: not running, skipping"
      fi

      # ── Journald rotation ────────────────────────────────────────────
      if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=14d 2>&1 | sed "s/^/$LOG_PREFIX journal-time: /" | tail -3
        journalctl --vacuum-size=200M 2>&1 | sed "s/^/$LOG_PREFIX journal-size: /" | tail -3
      fi

      # ── Nix gc + retroactive optimise ────────────────────────────────
      if command -v nix-collect-garbage >/dev/null 2>&1; then
        # --delete-older-than = drop generations >7d, NOT live current state
        nix-collect-garbage --delete-older-than 7d 2>&1 \
          | sed "s/^/$LOG_PREFIX nix-gc: /" | tail -5
      fi
      if command -v nix-store >/dev/null 2>&1; then
        # Retroactive hardlink dedup. Cheap if auto-optimise-store=true,
        # but VMs are Ubuntu+HM (no NixOS module) so this is the only
        # full-pass optimise that ever runs.
        nix-store --optimise 2>&1 \
          | sed "s/^/$LOG_PREFIX nix-optimise: /" | tail -3 || true
      fi

      # ── Disk after ───────────────────────────────────────────────────
      USAGE_AFTER=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
      AVAIL_AFTER_KB=$(df -P / | awk 'NR==2 { print $4 }')
      FREED_MB=$(( (AVAIL_AFTER_KB - AVAIL_BEFORE_KB) / 1024 ))
      echo "$LOG_PREFIX Disk after : ''${USAGE_AFTER}% used, $((AVAIL_AFTER_KB/1024))MB free (freed ''${FREED_MB}MB)"
      echo "$LOG_PREFIX === done ==="
    '';
  };

  home.file.".local/share/system-protection/infra-prune-maintenance.service".text = ''
    [Unit]
    Description=Infra prune maintenance — docker + nix + journald (daily, conservative)
    After=docker.service network.target
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/infra-prune-maintenance.sh
    User=root
    Nice=19
    IOSchedulingClass=idle
    OOMScoreAdjust=500
    TimeoutStartSec=30min
    StandardOutput=journal
    StandardError=journal
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/infra-prune-maintenance.timer".text = ''
    [Unit]
    Description=Daily infra prune maintenance (03:30)
    [Timer]
    OnCalendar=*-*-* 03:30:00
    RandomizedDelaySec=10min
    Persistent=true
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation: copy to /opt + /etc/systemd/system, enable, start ───
  home.activation.installPruneMaintenance = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[prune-maint-install] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[prune-maint-install] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/infra-prune-maintenance.sh"      /opt/scripts/infra-prune-maintenance.sh
    $SUDO chmod +x                                     /opt/scripts/infra-prune-maintenance.sh
    $SUDO cp -f "$SRC/infra-prune-maintenance.service" /etc/systemd/system/infra-prune-maintenance.service
    $SUDO cp -f "$SRC/infra-prune-maintenance.timer"   /etc/systemd/system/infra-prune-maintenance.timer

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable  infra-prune-maintenance.timer 2>/dev/null || true
    $SUDO systemctl restart infra-prune-maintenance.timer 2>/dev/null || true

    echo "[prune-maint-install] deployed: daily 03:30, conservative prune (no volume/--all)"
    ) || echo "[prune-maint-install] FAILED — activation continues"
  '';
}
