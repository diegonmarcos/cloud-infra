# System Protection — Layer 2: Identity (per-user slice limits)
#
# Caps ALL processes owned by a user (UID) — SSH sessions, docker compose,
# rsync, cron jobs — everything. This is the missing layer that caused
# gcp-proxy crash loops: docker compose CLI ran uncapped in user-1000.slice
# while only docker.slice (containers) was limited.
#
# systemd hierarchy: user.slice → user-{uid}.slice → user@{uid}.service
# Every process spawned by the user lands here automatically — inescapable.
#
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, userName ? "diego", userId ? 1000, ... }:

let
  # User slice gets generous but bounded limits
  # CPU: 75% — leaves 25% for kernel + FIFO services (sshd, wg)
  # Memory: high=75% (throttle), max=85% (kill) — prevents user processes from OOMing the system
  userCpuQuota = 75;
  userMemHighMB = ramMB * 75 / 100;
  userMemMaxMB  = ramMB * 85 / 100;

  userSliceConf = ''
    [Slice]
    Description=User ${userName} (UID ${toString userId}) resource limits
    CPUQuota=${toString userCpuQuota}%
    MemoryHigh=${toString userMemHighMB}M
    MemoryMax=${toString userMemMaxMB}M
    IOWeight=100
  '';

in {
  home.file.".local/share/system-protection/user-${toString userId}-slice-limits.conf".text = userSliceConf;

  home.activation.installLayer2Identity = lib.hm.dag.entryAfter ["installScheduler"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Deploy user slice drop-in
    $SUDO mkdir -p "/etc/systemd/system/user-${toString userId}.slice.d"
    $SUDO cp -f "$SRC/user-${toString userId}-slice-limits.conf" \
      "/etc/systemd/system/user-${toString userId}.slice.d/limits.conf"

    $SUDO systemctl daemon-reload

    echo "[layer2-identity] deployed: user-${toString userId}.slice CPU=${toString userCpuQuota}% MemHigh=${toString userMemHighMB}M MemMax=${toString userMemMaxMB}M"
    ) || echo "[layer2-identity] FAILED — activation continues"
  '';
}
