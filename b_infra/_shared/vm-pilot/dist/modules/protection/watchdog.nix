# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/protection/watchdog.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Disk Swap + Disk Watchdog + Kernel Watchdog Petter
# Disk swap (+ 24h defrag maintenance), disk watchdog (escalating cleanup
# with swap+docker budget awareness), kernel watchdog petter.
#
# Disk watchdog tiers:
#   85% WARN  — tmp/journals/docker prune (incl. images >72h)
#   90% CRIT  — aggressive prune (swap untouched)
#   95% EMERG — remove swapfile entirely + truncate logs + nix GC
#
# Split from: system-protection-watchdog-petter-dropbear-health-agent.nix
# Imported by: default.nix (via system-protection.nix orchestrator)
#
{ config, pkgs, lib, ramMB, ... }:

let
  diskSwapMB = if ramMB < 2048 then 2048 else ramMB;
in {
  # ── Disk swap ─────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/disk-swap.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      SWAPFILE="/swapfile"
      SWAP_MB=${toString diskSwapMB}

      if swapon --show=NAME 2>/dev/null | grep -q "$SWAPFILE"; then
        CURRENT=$(stat -c%s "$SWAPFILE" 2>/dev/null || echo 0)
        WANT=$(($SWAP_MB * 1024 * 1024))
        if [ "$CURRENT" -ge "$WANT" ]; then
          echo "[disk-swap] Already active ($(($CURRENT/1024/1024))MB), skipping"; exit 0
        fi
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
      fi

      if [ ! -f "$SWAPFILE" ]; then
        echo "[disk-swap] Creating ''${SWAP_MB}MB swapfile..."
        truncate -s 0 "$SWAPFILE"
        chattr +C "$SWAPFILE" 2>/dev/null || true
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=progress
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
      fi

      swapon -p 10 "$SWAPFILE"
      echo "[disk-swap] Activated ''${SWAP_MB}MB disk swap"
    '';
  };

  home.file.".local/share/system-protection/disk-swap.service".text = ''
    [Unit]
    Description=Disk-backed swap (${toString diskSwapMB}MB)
    After=local-fs.target
    Before=docker.service
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/disk-swap.sh
    [Install]
    WantedBy=multi-user.target
  '';

  # ── Disk swap maintenance (24h defrag cycle) ──────────────────────────
  home.file.".local/share/system-protection/disk-swap-maintenance.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      SWAPFILE="/swapfile"
      SWAP_MB=${toString diskSwapMB}

      # Check disk has room to recreate (need SWAP_MB + 1GB headroom)
      AVAIL_MB=$(df / --output=avail | tail -1 | tr -d ' ')
      AVAIL_MB=$((AVAIL_MB / 1024))
      NEED_MB=$((SWAP_MB + 1024))
      if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
        echo "[disk-swap-maint] Not enough space to recreate (''${AVAIL_MB}MB avail, need ''${NEED_MB}MB) — skipping"
        exit 0
      fi

      echo "[disk-swap-maint] Recreating ''${SWAP_MB}MB swapfile (defrag)..."
      swapoff "$SWAPFILE" 2>/dev/null || true
      rm -f "$SWAPFILE"
      truncate -s 0 "$SWAPFILE"
      chattr +C "$SWAPFILE" 2>/dev/null || true
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=progress
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE"
      swapon -p 10 "$SWAPFILE"
      echo "[disk-swap-maint] Done — ''${SWAP_MB}MB swapfile active"
    '';
  };

  home.file.".local/share/system-protection/disk-swap-maintenance.service".text = ''
    [Unit]
    Description=Swap file maintenance — recreate to defrag (${toString diskSwapMB}MB)
    After=disk-swap.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/disk-swap-maintenance.sh
  '';

  home.file.".local/share/system-protection/disk-swap-maintenance.timer".text = ''
    [Unit]
    Description=Recreate swapfile every 24h
    [Timer]
    OnBootSec=6h
    OnUnitActiveSec=24h
    [Install]
    WantedBy=timers.target
  '';

  # ── Disk watchdog ─────────────────────────────────────────────────────
  home.file.".local/share/system-protection/disk-watchdog.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      WARN=85; CRIT=90; EMERG=95

      # Budget awareness: report swapfile + docker total
      SWAP_SIZE_MB=0
      if [ -f /swapfile ]; then
        SWAP_SIZE_MB=$(($(stat -c%s /swapfile 2>/dev/null || echo 0) / 1024 / 1024))
      fi
      DOCKER_SIZE="N/A"
      if command -v docker >/dev/null 2>&1 && docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
        DOCKER_SIZE=$(docker system df --format '{{.Size}}' 2>/dev/null | paste -sd+ | bc 2>/dev/null || docker system df 2>/dev/null | awk 'NR>1{print $4}' | head -1 || echo "?")
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Root: ''${USAGE}% | swap=''${SWAP_SIZE_MB}MB | docker=$DOCKER_SIZE"
      [ "$USAGE" -lt "$WARN" ] && exit 0

      # ── WARN (85%) — gentle cleanup ──────────────────────────────────
      echo "[disk-watchdog] WARNING (''${USAGE}%) — cleaning"
      find /tmp -type f -atime +2 -delete 2>/dev/null || true
      find /var/tmp -type f -atime +2 -delete 2>/dev/null || true
      journalctl --vacuum-size=100M 2>/dev/null || true
      if command -v docker >/dev/null 2>&1; then
        docker container prune -f 2>/dev/null || true
        docker image prune -f 2>/dev/null || true
        docker builder prune -f --keep-storage=1G 2>/dev/null || true
        docker system prune -f --filter "until=72h" 2>/dev/null || true
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$CRIT" ] && echo "[disk-watchdog] Resolved ''${USAGE}%" && exit 0

      # ── CRIT (90%) — aggressive prune (swap untouched) ──────────────
      echo "[disk-watchdog] CRIT (''${USAGE}%) — aggressive cleanup"
      journalctl --vacuum-size=50M 2>/dev/null || true
      command -v docker >/dev/null 2>&1 && docker image prune -af 2>/dev/null && docker volume prune -f 2>/dev/null || true
      command -v nix-collect-garbage >/dev/null 2>&1 && nix-collect-garbage --delete-older-than 3d 2>/dev/null || true

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$EMERG" ] && echo "[disk-watchdog] Resolved ''${USAGE}%" && exit 0

      # ── EMERG (95%) — remove swapfile entirely + last resort ─────────
      echo "[disk-watchdog] EMERGENCY (''${USAGE}%) — last resort"

      # Remove swapfile entirely to free maximum disk space
      SWAPFILE="/swapfile"
      if [ -f "$SWAPFILE" ]; then
        FREED_MB=$(($(stat -c%s "$SWAPFILE" 2>/dev/null || echo 0) / 1024 / 1024))
        echo "[disk-watchdog] Removing swapfile to free ''${FREED_MB}MB"
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
      fi

      find /var/log -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null || true
      find /var/log -name "*.gz" -delete 2>/dev/null || true
      command -v nix-collect-garbage >/dev/null 2>&1 && nix-collect-garbage -d 2>/dev/null || true

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Final: ''${USAGE}%"
    '';
  };

  home.file.".local/share/system-protection/disk-watchdog.service".text = ''
    [Unit]
    Description=Disk usage watchdog
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/disk-watchdog.sh
  '';

  home.file.".local/share/system-protection/disk-watchdog.timer".text = ''
    [Unit]
    Description=Run disk watchdog every 5 minutes
    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min
    [Install]
    WantedBy=timers.target
  '';

  # ── Kernel Watchdog Petter ────────────────────────────────────────────
  home.file.".local/share/system-protection/watchdog-petter.sh" = {
    executable = true;
    source = ./watchdog-petter.sh;
  };

  home.file.".local/share/system-protection/watchdog-petter.service".text = ''
    [Unit]
    Description=Kernel Watchdog Petter — feeds /dev/watchdog, auto-heals containers, rich telemetry
    After=multi-user.target
    [Service]
    Type=simple
    ExecStart=/opt/scripts/watchdog-petter.sh
    OOMScoreAdjust=-999
    MemoryMax=32M
    MemoryMin=10M
    CPUQuota=10%
    Nice=-20
    Restart=always
    RestartSec=2
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installWatchdog = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[watchdog] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[watchdog] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/disk-swap.sh" /opt/scripts/disk-swap.sh
    $SUDO cp -f "$SRC/disk-swap-maintenance.sh" /opt/scripts/disk-swap-maintenance.sh
    $SUDO cp -f "$SRC/disk-watchdog.sh" /opt/scripts/disk-watchdog.sh
    $SUDO cp -f "$SRC/watchdog-petter.sh" /opt/scripts/watchdog-petter.sh
    $SUDO chmod +x /opt/scripts/disk-swap.sh /opt/scripts/disk-swap-maintenance.sh /opt/scripts/disk-watchdog.sh /opt/scripts/watchdog-petter.sh
    $SUDO cp -f "$SRC/disk-swap.service" /etc/systemd/system/disk-swap.service
    $SUDO cp -f "$SRC/disk-swap-maintenance.service" /etc/systemd/system/disk-swap-maintenance.service
    $SUDO cp -f "$SRC/disk-swap-maintenance.timer" /etc/systemd/system/disk-swap-maintenance.timer
    $SUDO cp -f "$SRC/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
    $SUDO cp -f "$SRC/disk-watchdog.timer" /etc/systemd/system/disk-watchdog.timer
    # watchdog-petter disabled — too aggressive, causes reboot loops
    $SUDO systemctl stop watchdog-petter.service 2>/dev/null || true
    $SUDO systemctl disable watchdog-petter.service 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/watchdog-petter.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable disk-swap.service disk-swap-maintenance.timer disk-watchdog.timer 2>/dev/null || true
    $SUDO systemctl start disk-swap.service 2>/dev/null || true
    $SUDO systemctl start disk-swap-maintenance.timer 2>/dev/null || true
    $SUDO systemctl start disk-watchdog.timer 2>/dev/null || true

    echo "[watchdog] deployed: disk-swap=${toString diskSwapMB}MB(+24h-maint) watchdog-petter=disabled"
    ) || echo "[watchdog] FAILED — activation continues"
  '';
}
