# Resource Bouncer + Janitor for Cloud VMs
#
# BOUNCER (kernel-level, denies access):
#   - CPU:  cgroup CPUQuota (handled by systemd slices on NixOS host)
#   - MEM:  sysctl vm.min_free_kbytes + zram + earlyoom kills hogs
#   - DISK: ext4 reserved blocks (5%) — non-root gets ENOSPC at 95%
#
# JANITOR (proactive cleanup):
#   - MEM:  earlyoom --prefer (kills browsers/nix-build first)
#   - DISK: disk-watchdog timer (escalating: logs→docker→nix GC)
#
# Deploys via sudo (same pattern as sshd-hardening.nix, idle-shutdown.nix):
#   - sysctl tuning:    /etc/sysctl.d/99-resource-bouncer.conf
#   - zram swap:        /etc/systemd/system/zram-setup.service
#   - earlyoom:         /etc/systemd/system/earlyoom.service
#   - disk watchdog:    /etc/systemd/system/disk-watchdog.{service,timer}
#   - reserved blocks:  tune2fs -m 5 (applied once at activation)
#
# Usage in VM config:
#   (import ./modules/resource-bouncer.nix { inherit config pkgs lib; ramMB = 1024; })
#
{ config, pkgs, lib, ramMB, ... }:

let
  # Scale kernel reserve by RAM size
  minFreeKB = if ramMB <= 1024 then 65536       # 64MB for <=1GB VMs
              else if ramMB <= 8192 then 131072  # 128MB for <=8GB VMs
              else 262144;                       # 256MB for >8GB VMs

  zramSizeMB = ramMB / 2;  # 50% of RAM
  zramSizeBytes = toString (zramSizeMB * 1024 * 1024);

in {
  # earlyoom binary + e2fsprogs for tune2fs (nix-managed, correct arch automatically)
  home.packages = [ pkgs.earlyoom pkgs.e2fsprogs ];

  # ─── Staged config files (copied to system locations by activation) ────

  home.file.".local/share/resource-bouncer/sysctl.conf".text = ''
    # Managed by home-manager (resource-bouncer.nix) — do not edit
    vm.min_free_kbytes = ${toString minFreeKB}
    vm.swappiness = 150
    vm.dirty_ratio = 10
    vm.dirty_background_ratio = 5
    vm.watermark_scale_factor = 500
  '';

  home.file.".local/share/resource-bouncer/zram-setup.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # zram compressed swap: ${toString zramSizeMB}MB (50% of ${toString ramMB}MB RAM)
      set -euo pipefail

      modprobe zram num_devices=1 2>/dev/null || true

      if swapon --show=NAME,TYPE 2>/dev/null | grep -q zram; then
        echo "[zram] Already active, skipping"
        exit 0
      fi

      # Reset and configure
      if [ -e /sys/block/zram0/reset ]; then
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
      fi
      echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || \
        echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
      echo ${zramSizeBytes} > /sys/block/zram0/disksize
      mkswap /dev/zram0
      swapon -p 100 /dev/zram0
      echo "[zram] Activated ${toString zramSizeMB}MB compressed swap"
    '';
  };

  home.file.".local/share/resource-bouncer/zram-setup.service".text = ''
    [Unit]
    Description=Setup zram compressed swap (${toString zramSizeMB}MB)
    After=local-fs.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/zram-setup.sh

    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/resource-bouncer/earlyoom.service".text = ''
    [Unit]
    Description=Early OOM Daemon (resource-bouncer)
    After=multi-user.target

    [Service]
    Type=simple
    ExecStart=${pkgs.earlyoom}/bin/earlyoom \
      -m 10 -s 10 \
      -M 5 -S 5 \
      --prefer "^(nix-daemon|nix-build|nix)$" \
      --avoid "^(sshd|systemd|earlyoom|dbus|dockerd|containerd)$" \
      -r 0
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  '';

  # ─── BOUNCER: protect critical services (SSH + WireGuard) ─────────────

  home.file.".local/share/resource-bouncer/sshd-bouncer.conf".text = ''
    # Managed by home-manager (resource-bouncer.nix) — do not edit
    [Service]
    MemoryMin=50M
    CPUWeight=1000
  '';

  home.file.".local/share/resource-bouncer/wg-quick-bouncer.conf".text = ''
    # Managed by home-manager (resource-bouncer.nix) — do not edit
    [Service]
    MemoryMin=30M
    CPUWeight=1000
  '';

  # ─── JANITOR: disk watchdog — prevent disk-full crashes ──────────────

  home.file.".local/share/resource-bouncer/disk-watchdog.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Disk watchdog — keeps root filesystem from hitting 100%
      # Escalating cleanup: logs → docker → tmp → journal → nix
      set -euo pipefail

      WARN_THRESHOLD=85
      CRIT_THRESHOLD=90
      EMERG_THRESHOLD=95

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Root disk usage: ''${USAGE}%"

      if [ "$USAGE" -lt "$WARN_THRESHOLD" ]; then
        echo "[disk-watchdog] OK — below ''${WARN_THRESHOLD}% threshold"
        exit 0
      fi

      echo "[disk-watchdog] WARNING: disk at ''${USAGE}% — starting cleanup"

      # Level 1 (>85%): Clean safe targets
      echo "[disk-watchdog] Level 1: cleaning logs and temp files"
      find /tmp -type f -atime +2 -delete 2>/dev/null || true
      find /var/tmp -type f -atime +2 -delete 2>/dev/null || true
      journalctl --vacuum-size=100M 2>/dev/null || true

      # Docker cleanup: dangling images, stopped containers, build cache
      if command -v docker >/dev/null 2>&1; then
        echo "[disk-watchdog] Level 1: pruning docker (dangling)"
        docker container prune -f 2>/dev/null || true
        docker image prune -f 2>/dev/null || true
        docker builder prune -f --keep-storage=1G 2>/dev/null || true
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$CRIT_THRESHOLD" ] && echo "[disk-watchdog] Resolved at ''${USAGE}%" && exit 0

      # Level 2 (>90%): More aggressive
      echo "[disk-watchdog] Level 2: aggressive cleanup (''${USAGE}%)"
      journalctl --vacuum-size=50M 2>/dev/null || true

      if command -v docker >/dev/null 2>&1; then
        # Remove ALL unused images (not just dangling)
        docker image prune -af 2>/dev/null || true
        docker volume prune -f 2>/dev/null || true
      fi

      # Nix garbage collection if available
      if command -v nix-collect-garbage >/dev/null 2>&1; then
        echo "[disk-watchdog] Level 2: nix GC (older than 3d)"
        nix-collect-garbage --delete-older-than 3d 2>/dev/null || true
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$EMERG_THRESHOLD" ] && echo "[disk-watchdog] Resolved at ''${USAGE}%" && exit 0

      # Level 3 (>95%): Emergency — truncate large logs
      echo "[disk-watchdog] CRITICAL: ''${USAGE}% — emergency cleanup"
      find /var/log -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null || true
      find /var/log -name "*.gz" -delete 2>/dev/null || true
      find /var/log -name "*.old" -delete 2>/dev/null || true

      if command -v nix-collect-garbage >/dev/null 2>&1; then
        echo "[disk-watchdog] Level 3: nix GC (all old generations)"
        nix-collect-garbage -d 2>/dev/null || true
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Final disk usage: ''${USAGE}%"
      if [ "$USAGE" -ge "$EMERG_THRESHOLD" ]; then
        echo "[disk-watchdog] ALERT: disk still at ''${USAGE}% after all cleanup — manual intervention needed"
      fi
    '';
  };

  home.file.".local/share/resource-bouncer/disk-watchdog.service".text = ''
    [Unit]
    Description=Disk usage watchdog (resource-bouncer)

    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/disk-watchdog.sh
  '';

  home.file.".local/share/resource-bouncer/disk-watchdog.timer".text = ''
    [Unit]
    Description=Run disk watchdog every 5 minutes

    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min

    [Install]
    WantedBy=timers.target
  '';

  # ─── Activation: deploy to system locations with sudo ──────────────────

  home.activation.installResourceBouncer = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[resource-bouncer] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[resource-bouncer] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/resource-bouncer"

    # ── BOUNCER: sysctl (memory) ──
    $SUDO mkdir -p /etc/sysctl.d
    $SUDO cp -f "$SRC/sysctl.conf" /etc/sysctl.d/99-resource-bouncer.conf
    $SUDO chmod 644 /etc/sysctl.d/99-resource-bouncer.conf
    $SUDO sysctl --system > /dev/null 2>&1 || true

    # ── BOUNCER: disk reserved blocks (ext4 only) ──
    # Reserve 5% of root filesystem for root — non-root processes get ENOSPC at 95%
    # Use tune2fs -m 5 directly (idempotent) — skip parsing, just set it
    ROOT_DEV=$($SUDO findmnt -n -o SOURCE / 2>/dev/null) || true
    ROOT_DEV=$(echo "$ROOT_DEV" | while read -r line; do echo "$line"; break; done)
    if [ -n "$ROOT_DEV" ] && $SUDO tune2fs -l "$ROOT_DEV" >/dev/null 2>&1; then
      $SUDO tune2fs -m 5 "$ROOT_DEV" 2>/dev/null || true
      echo "[resource-bouncer] Disk bouncer: ext4 reserved blocks set to 5% on $ROOT_DEV"
    else
      echo "[resource-bouncer] Disk bouncer: root is not ext4 — skipping reserved blocks"
    fi

    # ── BOUNCER: protect SSH + WireGuard (systemd drop-ins) ──
    # sshd: Ubuntu uses ssh.service, some use sshd.service — cover both
    for svc in ssh sshd; do
      if $SUDO systemctl cat "''${svc}.service" >/dev/null 2>&1; then
        $SUDO mkdir -p "/etc/systemd/system/''${svc}.service.d"
        $SUDO cp -f "$SRC/sshd-bouncer.conf" "/etc/systemd/system/''${svc}.service.d/bouncer.conf"
        echo "[resource-bouncer] Protected ''${svc}.service (MemoryMin=50M CPUWeight=1000)"
      fi
    done
    # WireGuard
    if $SUDO systemctl cat "wg-quick@wg0.service" >/dev/null 2>&1; then
      $SUDO mkdir -p "/etc/systemd/system/wg-quick@wg0.service.d"
      $SUDO cp -f "$SRC/wg-quick-bouncer.conf" "/etc/systemd/system/wg-quick@wg0.service.d/bouncer.conf"
      echo "[resource-bouncer] Protected wg-quick@wg0 (MemoryMin=30M CPUWeight=1000)"
    fi

    # ── BOUNCER + JANITOR: services ──
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/zram-setup.sh" /opt/scripts/zram-setup.sh
    $SUDO cp -f "$SRC/disk-watchdog.sh" /opt/scripts/disk-watchdog.sh
    $SUDO chmod +x /opt/scripts/zram-setup.sh /opt/scripts/disk-watchdog.sh
    $SUDO cp -f "$SRC/zram-setup.service" /etc/systemd/system/zram-setup.service
    $SUDO cp -f "$SRC/earlyoom.service" /etc/systemd/system/earlyoom.service
    $SUDO cp -f "$SRC/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
    $SUDO cp -f "$SRC/disk-watchdog.timer" /etc/systemd/system/disk-watchdog.timer

    # Enable and start
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable zram-setup.service earlyoom.service disk-watchdog.timer 2>/dev/null || true
    $SUDO systemctl start zram-setup.service 2>/dev/null || true
    $SUDO systemctl restart earlyoom.service 2>/dev/null || true
    $SUDO systemctl start disk-watchdog.timer 2>/dev/null || true

    echo "[resource-bouncer] deployed: bouncer(mem=${toString (minFreeKB / 1024)}MB-reserve zram=${toString zramSizeMB}MB disk=5%-reserved) janitor(earlyoom disk-watchdog=5min)"
    ) || echo "[resource-bouncer] FAILED — see errors above, activation continues"
  '';
}
