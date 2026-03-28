# System Protection — Resource Bouncer
# Memory: zram, earlyoom, sysctl, cgroup caps, Docker MemoryMax
# SSH/WG OOM immunity, ext4 reserved blocks
#
# Desktop equivalent: unix/aa_nixos-surface_host/src/modules/configuration_system-protection.nix
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, ... }:

let
  minFreeKB = if ramMB <= 1024 then 65536
              else if ramMB <= 8192 then 131072
              else 262144;

  zramSizeMB = ramMB / 2;
  zramSizeBytes = toString (zramSizeMB * 1024 * 1024);

  dockerMaxMB = if ramMB <= 1024 then ramMB - 350
                else if ramMB <= 8192 then ramMB - 512
                else ramMB - 1024;

in {
  home.packages = [ pkgs.earlyoom pkgs.e2fsprogs ];

  # ── Sysctl ────────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/sysctl.conf".text = ''
    # Managed by home-manager (system-protection-resource-bouncer.nix)
    vm.min_free_kbytes = ${toString minFreeKB}
    vm.swappiness = 150
    vm.dirty_ratio = 10
    vm.dirty_background_ratio = 5
    vm.watermark_scale_factor = 500
    net.ipv4.ip_forward = 1
  '';

  # ── Zram ──────────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/zram-setup.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      modprobe zram num_devices=1 2>/dev/null || true
      if swapon --show=NAME,TYPE 2>/dev/null | grep -q zram; then
        echo "[zram] Already active, skipping"; exit 0
      fi
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

  # ── Earlyoom ──────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/earlyoom.service".text = ''
    [Unit]
    Description=Early OOM Daemon (system-protection)
    After=multi-user.target
    [Service]
    Type=simple
    ExecStart=${pkgs.earlyoom}/bin/earlyoom \
      -m 10 -s 10 \
      --prefer "^(containerd-shim|nix-daemon|nix-build|nix)" \
      --avoid "^(sshd|ssh|systemd|earlyoom|dbus|wg-quick|wg)" \
      -r 0
    Restart=always
    RestartSec=2
    OOMScoreAdjust=-999
    MemoryMin=10M
    Nice=-20
    [Install]
    WantedBy=multi-user.target
  '';

  # SSH + WG + Docker scheduler configs moved to system-protection-scheduler-fifo-rr-cfs.nix

  # ── Docker memory cap ─────────────────────────────────────────────────
  home.file.".local/share/system-protection/docker-memory-cap.conf".text = ''
    [Service]
    MemoryMax=${toString dockerMaxMB}M
    MemoryHigh=${toString (dockerMaxMB * 9 / 10)}M
    OOMScoreAdjust=500
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installResourceBouncer = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[resource-bouncer] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[resource-bouncer] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Sysctl
    $SUDO mkdir -p /etc/sysctl.d
    $SUDO cp -f "$SRC/sysctl.conf" /etc/sysctl.d/99-system-protection.conf
    $SUDO chmod 644 /etc/sysctl.d/99-system-protection.conf
    $SUDO sysctl --system > /dev/null 2>&1 || true

    # Ext4 reserved blocks
    ROOT_DEV=$($SUDO findmnt -n -o SOURCE / 2>/dev/null) || true
    ROOT_DEV=$(echo "$ROOT_DEV" | while read -r line; do echo "$line"; break; done)
    if [ -n "$ROOT_DEV" ] && $SUDO tune2fs -l "$ROOT_DEV" >/dev/null 2>&1; then
      $SUDO tune2fs -m 5 "$ROOT_DEV" 2>/dev/null || true
    fi

    # SSH/WG/Docker scheduler drop-ins handled by system-protection-scheduler-fifo-rr-cfs.nix

    # Docker memory cap (separate from scheduler)
    if $SUDO systemctl cat "docker.service" >/dev/null 2>&1; then
      $SUDO mkdir -p "/etc/systemd/system/docker.service.d"
      $SUDO cp -f "$SRC/docker-memory-cap.conf" "/etc/systemd/system/docker.service.d/memory-cap.conf"
    fi

    # Services
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/zram-setup.sh" /opt/scripts/zram-setup.sh
    $SUDO chmod +x /opt/scripts/zram-setup.sh
    $SUDO cp -f "$SRC/zram-setup.service" /etc/systemd/system/zram-setup.service
    $SUDO cp -f "$SRC/earlyoom.service" /etc/systemd/system/earlyoom.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable zram-setup.service earlyoom.service 2>/dev/null || true
    $SUDO systemctl start zram-setup.service 2>/dev/null || true
    $SUDO systemctl restart earlyoom.service 2>/dev/null || true

    echo "[resource-bouncer] deployed: mem=${toString (minFreeKB / 1024)}MB-reserve zram=${toString zramSizeMB}MB docker-cap=${toString dockerMaxMB}MB"
    ) || echo "[resource-bouncer] FAILED — activation continues"
  '';
}
