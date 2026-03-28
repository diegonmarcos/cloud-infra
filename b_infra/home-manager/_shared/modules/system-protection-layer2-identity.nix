# System Protection — Layer 2: Identity & System Slice Hierarchy
#
# Three sub-slices under system.slice, each with a shared CPU budget:
#
#   system.slice/
#   ├── kernel.slice       → NO CAP    — bare minimum for Linux to function
#   ├── os-essentials.slice → 95% cap  — our protection + connectivity daemons
#   └── workload.slice      → 75% cap  — everything else (docker, containers, etc.)
#
# CPU budget guarantees (on a 1 vCPU machine):
#   kernel:        always gets at least 5%  (100% - 95%)
#   os-essentials: always gets at least 20% (95% - 75%)
#   workload:      capped at 75% total shared
#
# Plus: user-{uid}.slice capped at 75% (SSH sessions, compose CLI, etc.)
#
# Design: enumerate all active services, classify into one of three slices.
# Anything not explicitly in kernel or os-essentials → workload (capped).
# Re-runs on every HM activation — new services automatically get classified.
#
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, userName ? "diego", userId ? 1000, ... }:

let
  # ── Slice budgets ──────────────────────────────────────────────────────
  workloadCpuQuota = 75;
  osEssentialsCpuQuota = 95;
  # kernel.slice = no cap (implicit 100%)

  # ── User slice limits ─────────────────────────────────────────────────
  userCpuQuota = workloadCpuQuota;
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

  # ── Slice definitions ─────────────────────────────────────────────────
  kernelSliceConf = ''
    [Slice]
    Description=Kernel-essential services — no cap, Linux cannot function without these
  '';

  osEssentialsSliceConf = ''
    [Slice]
    Description=OS-essential services — protection, connectivity, monitoring
    CPUQuota=${toString osEssentialsCpuQuota}%
  '';

  workloadSliceConf = ''
    [Slice]
    Description=Workload services — docker, containers, application services
    CPUQuota=${toString workloadCpuQuota}%
  '';

  # ── Service classification ────────────────────────────────────────────
  # kernel.slice: bare minimum for Linux to boot and stay alive
  # Patterns: exact name or prefix (ending in - or @)
  kernelServices = [
    # systemd core
    "systemd-"              # prefix: journald, udevd, logind, resolved, networkd, timesyncd, etc.
    "dbus"
    "dbus-broker"
    "init.scope"
    # filesystem
    "mount"
    "swap"
    "fsck"
    "lvm2"
    "dm-event"
    "blk-availability"
    # login/session
    "getty@"                 # prefix: TTY logins
    "serial-getty@"          # prefix: serial consoles
    "user@"                  # prefix: user manager instances
    "user-runtime-dir@"      # prefix: user runtime dirs
    # network fundamentals
    "NetworkManager"
    "dhclient"
    "chrony"
    "ntp"
  ];

  # os-essentials.slice: our protection + connectivity daemons
  # These are services WE installed that must stay responsive
  osEssentialsServices = [
    # CONNECTIVITY (FIFO-protected — SSH, VPN, rescue)
    "sshd"
    "ssh"
    "wg-quick@"             # prefix: all WG interfaces
    "rescue-ssh"
    # PROTECTION (RR-protected — must never be throttled when system is stressed)
    "earlyoom"
    "watchdog-petter"
    # SWAP/MEMORY (our setup, critical for system stability)
    "zram-setup"
  ];

  # Everything else → workload.slice (capped at 75%)

  # Generate classification files (one pattern per line)
  kernelListText = lib.concatStringsSep "\n" kernelServices;
  osEssentialsListText = lib.concatStringsSep "\n" osEssentialsServices;

in {
  home.file = {
    # Slice definitions
    ".local/share/system-protection/kernel.slice".text = kernelSliceConf;
    ".local/share/system-protection/os-essentials.slice".text = osEssentialsSliceConf;
    ".local/share/system-protection/workload.slice".text = workloadSliceConf;
    # User slice
    ".local/share/system-protection/user-${toString userId}-slice-limits.conf".text = userSliceConf;
    # Classification lists
    ".local/share/system-protection/kernel-services.list".text = kernelListText;
    ".local/share/system-protection/os-essentials-services.list".text = osEssentialsListText;
  };

  home.activation.installLayer2Identity = lib.hm.dag.entryAfter ["installScheduler"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # ── Deploy slice definitions ─────────────────────────────────────────
    $SUDO cp -f "$SRC/kernel.slice" /etc/systemd/system/kernel.slice
    $SUDO cp -f "$SRC/os-essentials.slice" /etc/systemd/system/os-essentials.slice
    $SUDO cp -f "$SRC/workload.slice" /etc/systemd/system/workload.slice

    # ── Deploy user slice cap ────────────────────────────────────────────
    $SUDO mkdir -p "/etc/systemd/system/user-${toString userId}.slice.d"
    $SUDO cp -f "$SRC/user-${toString userId}-slice-limits.conf" \
      "/etc/systemd/system/user-${toString userId}.slice.d/limits.conf"

    # ── Classify services into slices ────────────────────────────────────
    # Helper: check if service matches any pattern in a list file
    matches_list() {
      _svc="$1"; _list="$2"
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        case "$pattern" in
          *@|*-)
            case "$_svc" in "$pattern"*) return 0 ;; esac
            ;;
          *)
            [ "$_svc" = "$pattern" ] && return 0
            ;;
        esac
      done < "$_list"
      return 1
    }

    KERNEL_COUNT=0
    ESSENTIAL_COUNT=0
    WORKLOAD_COUNT=0

    for svc in $($SUDO systemctl list-units --type=service --state=active,running \
                  --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}'); do

      svc_base="''${svc%.service}"

      # Determine target slice
      if matches_list "$svc_base" "$SRC/kernel-services.list"; then
        TARGET_SLICE="kernel.slice"
        KERNEL_COUNT=$((KERNEL_COUNT + 1))
      elif matches_list "$svc_base" "$SRC/os-essentials-services.list"; then
        TARGET_SLICE="os-essentials.slice"
        ESSENTIAL_COUNT=$((ESSENTIAL_COUNT + 1))
      else
        TARGET_SLICE="workload.slice"
        WORKLOAD_COUNT=$((WORKLOAD_COUNT + 1))
      fi

      # Deploy slice assignment drop-in
      $SUDO mkdir -p "/etc/systemd/system/''${svc}.d"
      printf '[Service]\nSlice=%s\n' "$TARGET_SLICE" | \
        $SUDO tee "/etc/systemd/system/''${svc}.d/slice-assignment.conf" > /dev/null
    done

    $SUDO systemctl daemon-reload

    echo "[layer2-identity] user-${toString userId}.slice CPU=${toString userCpuQuota}% MemHigh=${toString userMemHighMB}M MemMax=${toString userMemMaxMB}M"
    echo "[layer2-identity] system slices: kernel=$KERNEL_COUNT (no cap) | os-essentials=$ESSENTIAL_COUNT (${toString osEssentialsCpuQuota}%) | workload=$WORKLOAD_COUNT (${toString workloadCpuQuota}%)"
    ) || echo "[layer2-identity] FAILED — activation continues"
  '';
}
