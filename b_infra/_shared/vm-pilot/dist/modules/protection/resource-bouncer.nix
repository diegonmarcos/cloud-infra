# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/protection/resource-bouncer.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Resource Bouncer
# Memory: zram, earlyoom, sysctl, cgroup caps, Docker MemoryMax
# SSH/WG OOM immunity, ext4 reserved blocks
#
# Desktop equivalent: unix/aa_nixos-surface_host/src/modules/configuration_system-protection.nix
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, ... }:

let
  # Clamp helper: compute then enforce absolute min/max
  clamp = min: max: v: if v < min then min else if v > max then max else v;

  # Sane RAM range: 1GB–36GB (cloud-data may return 0 if terraform parsing fails)
  safeRamMB = clamp 1024 36864 (if ramMB > 0 then ramMB else 1024);

  minFreeKB = if safeRamMB <= 1024 then 65536
              else if safeRamMB <= 8192 then 131072
              else 262144;

  # zram: 50% of RAM, min 256MB, max 16GB
  zramSizeMB = clamp 256 16384 (safeRamMB / 2);
  zramSizeBytes = toString (zramSizeMB * 1024 * 1024);

  # Docker memory cap: RAM minus OS overhead, min 256MB, max 32GB
  dockerMaxMB = clamp 256 32768 (
    if safeRamMB <= 1024 then safeRamMB - 350
    else if safeRamMB <= 8192 then safeRamMB - 512
    else safeRamMB - 1024
  );

in {
  # earlyoom package dropped 2026-07-03 with the disabled unit below (ONLY-PSI directive)
  home.packages = [ pkgs.e2fsprogs ];

  # ── Sysctl ────────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/sysctl.conf".text = ''
    # Managed by home-manager (system-protection-resource-bouncer.nix)
    vm.min_free_kbytes = ${toString minFreeKB}
    vm.swappiness = 150
    vm.dirty_ratio = 10
    vm.dirty_background_ratio = 5
    vm.watermark_scale_factor = 500
    net.ipv4.ip_forward = 1
    # ── File-descriptor / inotify / PID exhaustion headroom ──────────────
    # 2026-06-19 incident: a fluent-bit fd leak drained the SYSTEM fd table on
    # gcp-proxy → every daemon (incl. FIFO-priority sshd / wg-quick / dropbear)
    # got EMFILE (errno 24) on accept()/open() → the whole WG hub went
    # unreachable while CPU+memory protection still looked healthy. cgroup
    # CPU/mem slices CANNOT cap file descriptors, inotify watches, or PIDs —
    # those live in global kernel tables. Give those tables massive headroom so
    # a single leaking process can never exhaust them (defence-in-depth with the
    # per-service LimitNOFILE caps on fluent-bit + docker). 8 GB RAM ceiling is
    # irrelevant: each struct file is ~1 KB, 2M fds ≈ worst case the offender
    # never reaches because it is LimitNOFILE-capped first.
    fs.file-max = 2097152
    fs.nr_open = 2097152
    fs.inotify.max_user_watches = 524288
    fs.inotify.max_user_instances = 1024
    kernel.pid_max = 262144
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
  # DISABLED 2026-07-03 (user directive: 'remove ALL non-PSI triggers, ONLY
  # PSI'). earlyoom has no PSI awareness at all — it is purely absolute
  # free-mem%/free-swap% (-m 10 -s 10), the same class of bug that made the
  # desktop's earlyoom false-kill plasmashell at PSI≈0. load-shedder.nix
  # (armed, MEMORY-PSI-ONLY, memPsiCrit=50%) is this fleet's real memory-
  # thrash protection — genuinely PSI-gated per its own header contract.
  # Unit definition kept (commented ExecStart removed from activation below)
  # so it can be restored if a non-PSI last-resort backstop is ever wanted.

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

    # Ext4 reserved blocks: REMOVED 2026-05-06 — disk-ballast.nix is the
    # single source of truth for disk reservation now (universal across
    # ext4 + btrfs, declarative size, root-deletable on demand by the
    # engine pre-flight). resource-bouncer setting -m 5 here was undoing
    # disk-ballast's `-m 0` and double-reserving disk we already own
    # via the userland ballast file.

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

    # earlyoom: disabled + torn down 2026-07-03 (ONLY-PSI directive) — it has
    # no PSI awareness (absolute mem/swap% only); load-shedder.service is the
    # real PSI-based memory-thrash protection for this fleet.
    $SUDO systemctl stop earlyoom.service 2>/dev/null || true
    $SUDO systemctl disable earlyoom.service 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/earlyoom.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable zram-setup.service 2>/dev/null || true
    $SUDO systemctl start zram-setup.service 2>/dev/null || true

    echo "[resource-bouncer] deployed: mem=${toString (minFreeKB / 1024)}MB-reserve zram=${toString zramSizeMB}MB docker-cap=${toString dockerMaxMB}MB"
    ) || echo "[resource-bouncer] FAILED — activation continues"
  '';
}
