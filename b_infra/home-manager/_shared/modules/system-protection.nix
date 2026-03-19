# System Protection Module — OS-level resilience (separate from apps/libs)
#
# This module provides kernel-level resource protection to prevent system
# lockups and ensure critical services (SSH, WireGuard) always remain accessible.
#
# BOUNCER (kernel denies access):
#   - Memory: sysctl vm.min_free_kbytes + zram compressed swap
#   - Memory: earlyoom kills hogs before OOM
#   - Disk:   ext4 reserved blocks (5%) — non-root gets ENOSPC at 95%
#   - SSH:    MemoryMin=50M CPUWeight=1000 (kernel guarantees)
#   - WG:     MemoryMin=30M CPUWeight=1000 (kernel guarantees)
#
# JANITOR (proactive cleanup):
#   - Memory: earlyoom --prefer nix-build/browsers --avoid sshd/systemd
#   - Disk:   watchdog timer (5min) — escalating cleanup at 85%/90%/95%
#
# Usage in VM config:
#   (import ./modules/system-protection.nix { inherit config pkgs lib; ramMB = 1024; })
#
{ config, pkgs, lib, ramMB, ... }:

let
  # Scale kernel reserve by RAM size
  minFreeKB = if ramMB <= 1024 then 65536       # 64MB for <=1GB VMs
              else if ramMB <= 8192 then 131072  # 128MB for <=8GB VMs
              else 262144;                       # 256MB for >8GB VMs

  zramSizeMB = ramMB / 2;  # 50% of RAM
  zramSizeBytes = toString (zramSizeMB * 1024 * 1024);

  # Disk swap: max(2GB, 100% RAM) — scales with VM size
  diskSwapMB = if ramMB < 2048 then 2048 else ramMB;

in {
  # earlyoom + e2fsprogs (for tune2fs)
  home.packages = [ pkgs.earlyoom pkgs.e2fsprogs ];

  # ═══════════════════════════════════════════════════════════════════════
  # STAGED CONFIG FILES (deployed by activation script)
  # ═══════════════════════════════════════════════════════════════════════

  # ── Sysctl (memory bouncer) ────────────────────────────────────────────
  home.file.".local/share/system-protection/sysctl.conf".text = ''
    # Managed by home-manager (system-protection.nix) — do not edit
    vm.min_free_kbytes = ${toString minFreeKB}
    vm.swappiness = 150
    vm.dirty_ratio = 10
    vm.dirty_background_ratio = 5
    vm.watermark_scale_factor = 500
    # Docker/WireGuard need IP forwarding — override GCP's 60-gce-network-security.conf
    net.ipv4.ip_forward = 1
  '';

  # ── Zram setup script ──────────────────────────────────────────────────
  home.file.".local/share/system-protection/zram-setup.sh" = {
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

  home.file.".local/share/system-protection/zram-setup.service".text = ''
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

  # ── Disk swap (for low-RAM VMs where zram alone isn't enough) ─────────
  # Creates a 2GB swapfile on disk. Unlike zram, this provides real extra memory.
  # Only activates on VMs with <=1GB RAM where Docker OOM is a real risk.
  home.file.".local/share/system-protection/disk-swap.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Disk-backed swap: max(2GB, 100% RAM) — ${toString diskSwapMB}MB for this VM
      set -euo pipefail
      SWAPFILE="/swapfile"
      SWAP_MB=${toString diskSwapMB}

      if swapon --show=NAME 2>/dev/null | grep -q "$SWAPFILE"; then
        CURRENT=$(stat -c%s "$SWAPFILE" 2>/dev/null || echo 0)
        WANT=$(($SWAP_MB * 1024 * 1024))
        if [ "$CURRENT" -ge "$WANT" ]; then
          echo "[disk-swap] Already active ($(($CURRENT/1024/1024))MB), skipping"
          exit 0
        fi
        echo "[disk-swap] Existing swap too small ($(($CURRENT/1024/1024))MB < ${toString diskSwapMB}MB), recreating..."
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
      fi

      if [ ! -f "$SWAPFILE" ]; then
        echo "[disk-swap] Creating ''${SWAP_MB}MB swapfile (btrfs-safe)..."
        truncate -s 0 "$SWAPFILE"
        chattr +C "$SWAPFILE" 2>/dev/null || true
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=progress
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
      fi

      swapon -p 10 "$SWAPFILE"
      echo "[disk-swap] Activated ''${SWAP_MB}MB disk swap (priority 10, zram has priority 100)"
    '';
  };

  home.file.".local/share/system-protection/disk-swap.service".text = ''
    [Unit]
    Description=Disk-backed swap (${toString diskSwapMB}MB) for VM
    After=local-fs.target
    Before=docker.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/disk-swap.sh

    [Install]
    WantedBy=multi-user.target
  '';

  # ── Earlyoom (memory janitor) ──────────────────────────────────────────
  home.file.".local/share/system-protection/earlyoom.service".text = ''
    [Unit]
    Description=Early OOM Daemon (system-protection)
    After=multi-user.target

    [Service]
    Type=simple
    ExecStart=${pkgs.earlyoom}/bin/earlyoom \
      -m 10 -s 10 \
      -M 5 -S 5 \
      --prefer "^(nix-daemon|nix-build|nix)$" \
      --avoid "^(sshd|systemd|earlyoom|dbus|dockerd|containerd|wg-quick)$" \
      -r 0
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  '';

  # ── SSH protection (systemd drop-in) ───────────────────────────────────
  home.file.".local/share/system-protection/sshd-protection.conf".text = ''
    # Managed by home-manager (system-protection.nix) — do not edit
    [Service]
    MemoryMin=50M
    CPUWeight=1000
  '';

  # ── WireGuard protection (systemd drop-in) ─────────────────────────────
  home.file.".local/share/system-protection/wg-quick-protection.conf".text = ''
    # Managed by home-manager (system-protection.nix) — do not edit
    [Service]
    MemoryMin=30M
    CPUWeight=1000
  '';

  # ── Disk watchdog script (janitor) ─────────────────────────────────────
  home.file.".local/share/system-protection/disk-watchdog.sh" = {
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

  home.file.".local/share/system-protection/disk-watchdog.service".text = ''
    [Unit]
    Description=Disk usage watchdog (system-protection)

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

  # ═══════════════════════════════════════════════════════════════════════
  # ACTIVATION: Deploy to system with sudo
  # ═══════════════════════════════════════════════════════════════════════

  home.activation.installSystemProtection = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[system-protection] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[system-protection] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/system-protection"

    # ── BOUNCER: sysctl (memory) ──
    $SUDO mkdir -p /etc/sysctl.d
    $SUDO cp -f "$SRC/sysctl.conf" /etc/sysctl.d/99-system-protection.conf
    $SUDO chmod 644 /etc/sysctl.d/99-system-protection.conf
    $SUDO sysctl --system > /dev/null 2>&1 || true

    # ── BOUNCER: disk reserved blocks (ext4 only) ──
    # Reserve 5% of root filesystem for root — non-root processes get ENOSPC at 95%
    # Use tune2fs -m 5 directly (idempotent) — skip parsing, just set it
    ROOT_DEV=$($SUDO findmnt -n -o SOURCE / 2>/dev/null) || true
    ROOT_DEV=$(echo "$ROOT_DEV" | while read -r line; do echo "$line"; break; done)
    if [ -n "$ROOT_DEV" ] && $SUDO tune2fs -l "$ROOT_DEV" >/dev/null 2>&1; then
      $SUDO tune2fs -m 5 "$ROOT_DEV" 2>/dev/null || true
      echo "[system-protection] Disk bouncer: ext4 reserved blocks set to 5% on $ROOT_DEV"
    else
      echo "[system-protection] Disk bouncer: root is not ext4 — skipping reserved blocks"
    fi

    # ── BOUNCER: protect SSH + WireGuard (systemd drop-ins) ──
    # sshd: Ubuntu uses ssh.service, some use sshd.service — cover both
    for svc in ssh sshd; do
      if $SUDO systemctl cat "''${svc}.service" >/dev/null 2>&1; then
        $SUDO mkdir -p "/etc/systemd/system/''${svc}.service.d"
        $SUDO cp -f "$SRC/sshd-protection.conf" "/etc/systemd/system/''${svc}.service.d/protection.conf"
        echo "[system-protection] Protected ''${svc}.service (MemoryMin=50M CPUWeight=1000)"
      fi
    done
    # WireGuard
    if $SUDO systemctl cat "wg-quick@wg0.service" >/dev/null 2>&1; then
      $SUDO mkdir -p "/etc/systemd/system/wg-quick@wg0.service.d"
      $SUDO cp -f "$SRC/wg-quick-protection.conf" "/etc/systemd/system/wg-quick@wg0.service.d/protection.conf"
      echo "[system-protection] Protected wg-quick@wg0 (MemoryMin=30M CPUWeight=1000)"
    fi

    # ── BOUNCER + JANITOR: services ──
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/zram-setup.sh" /opt/scripts/zram-setup.sh
    $SUDO cp -f "$SRC/disk-swap.sh" /opt/scripts/disk-swap.sh
    $SUDO cp -f "$SRC/disk-watchdog.sh" /opt/scripts/disk-watchdog.sh
    $SUDO chmod +x /opt/scripts/zram-setup.sh /opt/scripts/disk-swap.sh /opt/scripts/disk-watchdog.sh
    $SUDO cp -f "$SRC/zram-setup.service" /etc/systemd/system/zram-setup.service
    $SUDO cp -f "$SRC/disk-swap.service" /etc/systemd/system/disk-swap.service
    $SUDO cp -f "$SRC/earlyoom.service" /etc/systemd/system/earlyoom.service
    $SUDO cp -f "$SRC/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
    $SUDO cp -f "$SRC/disk-watchdog.timer" /etc/systemd/system/disk-watchdog.timer

    # Enable and start
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable zram-setup.service disk-swap.service earlyoom.service disk-watchdog.timer 2>/dev/null || true
    $SUDO systemctl start disk-swap.service 2>/dev/null || true
    $SUDO systemctl start zram-setup.service 2>/dev/null || true
    $SUDO systemctl restart earlyoom.service 2>/dev/null || true
    $SUDO systemctl start disk-watchdog.timer 2>/dev/null || true

    echo "[system-protection] deployed: bouncer(mem=${toString (minFreeKB / 1024)}MB-reserve zram=${toString zramSizeMB}MB disk=5%-reserved ssh+wg=protected) janitor(earlyoom disk-watchdog=5min)"
    ) || echo "[system-protection] FAILED — see errors above, activation continues"
  '';
}
