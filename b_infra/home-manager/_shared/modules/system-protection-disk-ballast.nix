# System Protection — Disk Ballast (rescue reserve)
#
# Pre-allocates a configurable % of / as a ballast file. When disk hits EMERG
# (95%), the watchdog deletes the ballast → instant N% free, BEFORE touching
# swap (which would expose OOM risk).
#
# Why this exists:
#   ext4 reserved blocks (`tune2fs -m 5`) only protect uid 0 — useless when the
#   daemon filling the disk IS root (docker, journalctl, nix-daemon). zram +
#   swap help with memory pressure, not disk pressure. The ballast is a
#   userland-visible, root-deletable reservation: nothing else can claim it,
#   and the watchdog can free it instantly without OOM consequences.
#
# Deletion order in watchdog EMERG tier:
#   1. ballast       (reversible, recreated when /< 70%, no OOM risk)
#   2. swapfile      (last resort; removing it exposes processes to OOM)
#
# Imported by: system-protection.nix (orchestrator)
{ config, pkgs, lib, ... }:

let
  ballastPercent = 5;
  ballastPath = "/var/disk-reserve/ballast.bin";
  recreateThreshold = 70;  # only allocate when /<70%
in {
  # ── Ballast creator script ────────────────────────────────────────────
  home.file.".local/share/system-protection/disk-ballast-create.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Allocate ${toString ballastPercent}% of / as a rescue ballast file.
      # Idempotent: skips if file already exists at target size.
      # Safe: refuses to allocate if /<${toString recreateThreshold}% would be exceeded.
      set -euo pipefail
      BALLAST="${ballastPath}"
      DIR=$(dirname "$BALLAST")
      mkdir -p "$DIR"
      chmod 700 "$DIR"

      # POSIX df -P: portable across GNU coreutils + BusyBox.
      # Format: Filesystem 1024-blocks Used Available Capacity Mounted-on
      TOTAL_KB=$(df -P / | awk 'NR==2 { print $2 }')
      WANT_MB=$(( TOTAL_KB * ${toString ballastPercent} / 100 / 1024 ))

      if [ -f "$BALLAST" ]; then
        HAVE_MB=$(($(stat -c%s "$BALLAST" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$HAVE_MB" -ge "$WANT_MB" ]; then
          echo "[disk-ballast] OK ''${HAVE_MB}MB present (target ''${WANT_MB}MB) — no-op"
          exit 0
        fi
        echo "[disk-ballast] Resizing: ''${HAVE_MB}MB → ''${WANT_MB}MB"
        rm -f "$BALLAST"
      fi

      USAGE=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
      if [ "$USAGE" -ge ${toString recreateThreshold} ]; then
        echo "[disk-ballast] Usage ''${USAGE}% ≥ ${toString recreateThreshold}% — refusing to allocate (free disk first)"
        exit 0
      fi

      echo "[disk-ballast] Allocating ''${WANT_MB}MB at $BALLAST (${toString ballastPercent}% of /)"
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "''${WANT_MB}M" "$BALLAST"
      else
        dd if=/dev/zero of="$BALLAST" bs=1M count="$WANT_MB" status=none
      fi
      chmod 600 "$BALLAST"
      echo "[disk-ballast] Reserved ''${WANT_MB}MB for rescue"
    '';
  };

  # ── Boot-time service: allocate at boot ───────────────────────────────
  home.file.".local/share/system-protection/disk-ballast-create.service".text = ''
    [Unit]
    Description=Pre-allocate disk ballast (${toString ballastPercent}% rescue reserve)
    After=local-fs.target
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/disk-ballast-create.sh
  '';

  # ── Hourly recreate timer (after watchdog EMERG removed it) ──────────
  home.file.".local/share/system-protection/disk-ballast-create.timer".text = ''
    [Unit]
    Description=Recreate disk ballast when /<${toString recreateThreshold}%
    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=1h
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installDiskBallast = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[disk-ballast] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[disk-ballast] no sudo — skipping" && exit 0
    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/disk-ballast-create.sh" /opt/scripts/disk-ballast-create.sh
    $SUDO chmod +x /opt/scripts/disk-ballast-create.sh
    $SUDO cp -f "$SRC/disk-ballast-create.service" /etc/systemd/system/disk-ballast-create.service
    $SUDO cp -f "$SRC/disk-ballast-create.timer" /etc/systemd/system/disk-ballast-create.timer
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable disk-ballast-create.timer 2>/dev/null || true
    $SUDO systemctl start disk-ballast-create.service 2>/dev/null || true
    echo "[disk-ballast] deployed: ${toString ballastPercent}% reserve at ${ballastPath}"
    ) || echo "[disk-ballast] FAILED — activation continues"
  '';
}
