# System Protection — Layer 2: Identity
#
# Two responsibilities:
#   A) User slice: caps ALL processes for UID (SSH, compose, rsync — everything)
#   B) System service filter: enumerates all active services, caps anything
#      NOT in the OS-essential allowlist at 75% CPU. New services automatically
#      get capped — the allowlist is the source of truth, not the cap list.
#
# Design: "whitelist essential, cap everything else"
#   - systemd is the source of truth for what's running
#   - we define what's essential (OS/kernel/protection)
#   - anything else = 75% CPU cap via drop-in
#   - re-runs on every HM activation (picks up new services)
#
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, userName ? "diego", userId ? 1000, ... }:

let
  # ── Default cap for non-essential services ─────────────────────────────
  defaultCpuQuota = 75;

  # ── A) User slice limits ───────────────────────────────────────────────
  userCpuQuota = defaultCpuQuota;
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

  # ── B) OS-essential allowlist ──────────────────────────────────────────
  # These services get NO cap (100% CPU). Everything else = 75%.
  # Patterns: exact match or prefix match (for template units like getty@*)
  #
  # Categories:
  #   KERNEL/INIT  — systemd itself, udev, dbus, journald
  #   CONNECTIVITY — sshd, wg-quick, rescue-ssh (FIFO-protected)
  #   PROTECTION   — earlyoom, watchdog-petter (RR-protected, must never throttle)
  #   FILESYSTEM   — mount, swap, fsck
  #   NETWORK      — resolved, networkd, timesyncd, dhclient
  #   LOGIN        — getty, serial-getty, logind
  essentialServices = [
    # KERNEL/INIT
    "systemd-"          # prefix: ALL systemd-* services (journald, udevd, logind, etc.)
    "dbus"
    "dbus-broker"
    "init.scope"
    # CONNECTIVITY
    "sshd"
    "ssh"
    "wg-quick@"         # prefix: all WG interfaces
    "rescue-ssh"
    # PROTECTION (must never be throttled)
    "earlyoom"
    "watchdog-petter"
    # FILESYSTEM
    "mount"
    "swap"
    "fsck"
    "zram-setup"
    "lvm2"
    "dm-event"
    "blk-availability"
    # NETWORK
    "NetworkManager"
    "systemd-resolved"
    "systemd-networkd"
    "systemd-timesyncd"
    "dhclient"
    "chrony"
    "ntp"
    # LOGIN
    "getty@"             # prefix: all TTY logins
    "serial-getty@"      # prefix: serial consoles
    "user@"              # prefix: user manager instances
    "user-runtime-dir@"  # prefix: user runtime dirs
    # CGROUP/SLICE management
    "-.slice"
    "system.slice"
    "user.slice"
  ];

  # Generate the allowlist file (one pattern per line)
  essentialListText = lib.concatStringsSep "\n" essentialServices;

  # Drop-in content for capped services
  capConf = ''
    [Service]
    CPUQuota=${toString defaultCpuQuota}%
  '';

in {
  home.file = {
    ".local/share/system-protection/user-${toString userId}-slice-limits.conf".text = userSliceConf;
    ".local/share/system-protection/essential-services.list".text = essentialListText;
    ".local/share/system-protection/default-cap.conf".text = capConf;
  };

  home.activation.installLayer2Identity = lib.hm.dag.entryAfter ["installScheduler"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # ── A) Deploy user slice cap ──────────────────────────────────────────
    $SUDO mkdir -p "/etc/systemd/system/user-${toString userId}.slice.d"
    $SUDO cp -f "$SRC/user-${toString userId}-slice-limits.conf" \
      "/etc/systemd/system/user-${toString userId}.slice.d/limits.conf"

    # ── B) Dynamic system service filter ──────────────────────────────────
    # Enumerate all active services, cap anything not in essential allowlist
    CAPPED=0
    SKIPPED=0

    for svc in $($SUDO systemctl list-units --type=service --state=active,running \
                  --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}'); do

      # Strip .service suffix for matching
      svc_base="''${svc%.service}"

      # Check against allowlist (exact match or prefix match)
      IS_ESSENTIAL=0
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        # Prefix match: pattern ends with special chars like @ or -
        case "$pattern" in
          *@|*-)
            case "$svc_base" in
              "$pattern"*) IS_ESSENTIAL=1; break ;;
            esac
            ;;
          *)
            [ "$svc_base" = "$pattern" ] && IS_ESSENTIAL=1 && break
            ;;
        esac
      done < "$SRC/essential-services.list"

      if [ "$IS_ESSENTIAL" = "0" ]; then
        # Not essential — apply default cap
        # Skip if service already has a scheduler.conf (Layer 3 handles it)
        if [ -f "/etc/systemd/system/''${svc}.d/scheduler.conf" ]; then
          SKIPPED=$((SKIPPED + 1))
        else
          $SUDO mkdir -p "/etc/systemd/system/''${svc}.d"
          $SUDO cp -f "$SRC/default-cap.conf" "/etc/systemd/system/''${svc}.d/cpu-cap.conf"
          CAPPED=$((CAPPED + 1))
        fi
      fi
    done

    $SUDO systemctl daemon-reload

    echo "[layer2-identity] user-${toString userId}.slice CPU=${toString userCpuQuota}% MemHigh=${toString userMemHighMB}M MemMax=${toString userMemMaxMB}M"
    echo "[layer2-identity] system services: $CAPPED capped at ${toString defaultCpuQuota}% | $SKIPPED already managed by layer3"
    ) || echo "[layer2-identity] FAILED — activation continues"
  '';
}
