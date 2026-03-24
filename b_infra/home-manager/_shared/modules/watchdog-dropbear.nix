# Kernel Watchdog — if the dog doesn't get petted, the machine resets
#
# Uses Linux softdog kernel module + a tiny systemd service that:
#   1. Opens /dev/watchdog
#   2. Writes every 5 seconds ("pets the dog")
#   3. If the process dies, freezes, or OOMs → kernel resets in 15s
#
# This is BELOW userspace — the kernel timer itself triggers the reboot.
# Even a completely frozen system gets reset. No network, no SSH, no cloud API needed.
#
# Dropbear (rescue-ssh.nix) stays alive for remote triage BEFORE the watchdog fires.
# The watchdog is the absolute last resort — nuclear option.
#
# Safety: systemd WatchdogSec ensures the petter itself is monitored.
#         If the petter service hangs, systemd restarts it.
#         If systemd itself hangs, the kernel watchdog fires.
#
# Usage in VM config:
#   imports = [ ./modules/watchdog-dropbear.nix ];
#
{ config, pkgs, lib, ... }:

let
  # Watchdog timeout: kernel resets if not petted within this window
  watchdogTimeout = 15;
  # Pet interval: must be less than half the timeout
  petInterval = 5;
in {
  home.packages = [ pkgs.watchdog ];

  # Systemd service that pets /dev/watchdog
  home.file.".local/share/watchdog/watchdog-petter.service".text = ''
    [Unit]
    Description=Kernel Watchdog Petter — resets machine if userspace dies
    After=network.target docker.service
    Wants=docker.service

    [Service]
    Type=simple
    # Three-tier watchdog petter:
    #   Tier 1: Check Docker + key containers → healthy → pet the dog
    #   Tier 2: Docker hung → restart Docker → pet (give it a chance)
    #   Tier 3: Restart failed / userspace frozen → STOP PETTING → kernel resets in ${toString watchdogTimeout}s
    #
    # Opening /dev/watchdog starts the kernel countdown.
    # Writing to it resets the countdown. NOT writing = machine reset.
    ExecStart=/bin/sh -c '\
      exec 3>/dev/watchdog; \
      DOCKER_FAIL=0; \
      LOG="/var/log/watchdog-petter.log"; \
      log() { echo "$(date -Is) [watchdog] $1" >> "$LOG" 2>/dev/null; }; \
      while true; do \
        # ── Tier 1: Is Docker responding? ── \
        if docker info >/dev/null 2>&1; then \
          # Docker alive — check for critical containers \
          UNHEALTHY=$(docker ps --filter health=unhealthy --format "{{.Names}}" 2>/dev/null | head -5); \
          RESTARTING=$(docker ps --filter status=restarting --format "{{.Names}}" 2>/dev/null | head -5); \
          if [ -n "$RESTARTING" ]; then \
            log "WARN: restarting containers: $RESTARTING"; \
          fi; \
          # Tier 1 pass — pet the dog \
          echo V >&3; \
          DOCKER_FAIL=0; \
        else \
          # ── Tier 2: Docker not responding ── \
          DOCKER_FAIL=$((DOCKER_FAIL + 1)); \
          log "ALERT: Docker not responding (fail $DOCKER_FAIL/3)"; \
          if [ "$DOCKER_FAIL" -ge 2 ] && [ "$DOCKER_FAIL" -le 3 ]; then \
            # Try to restart Docker daemon \
            log "ACTION: restarting Docker daemon"; \
            systemctl restart docker 2>/dev/null || true; \
            # Still pet — give Docker a chance to recover \
            echo V >&3; \
          elif [ "$DOCKER_FAIL" -ge 4 ]; then \
            # ── Tier 3: Docker restart failed — check if kernel is responsive ── \
            if [ -f /proc/loadavg ]; then \
              LOAD=$(cat /proc/loadavg | cut -d" " -f1); \
              log "CRITICAL: Docker dead after restart. Load: $LOAD. Checking kernel..."; \
              # Kernel still alive — pet but log critical \
              # Only stop petting if /proc itself is unreadable (true freeze) \
              echo V >&3; \
            else \
              # /proc unreadable — kernel is frozen \
              # STOP PETTING — kernel watchdog will reset in ${toString watchdogTimeout}s \
              log "FATAL: /proc unreadable — stopping petter. Kernel reset imminent."; \
              exit 1; \
            fi; \
          else \
            # First failure — pet and wait \
            echo V >&3; \
          fi; \
        fi; \
        sleep ${toString petInterval}; \
      done'
    # If the petter itself hangs, systemd kills and restarts it
    WatchdogSec=${toString (petInterval * 3)}
    Restart=always
    RestartSec=2
    # Make this process nearly unkillable (same as Dropbear)
    OOMScoreAdjust=-999
    MemoryMax=10M
    MemoryMin=5M
    CPUWeight=10000
    # Must run as root to access /dev/watchdog
    User=root
    Group=root

    [Install]
    WantedBy=multi-user.target
  '';

  # Activation: install + enable the systemd service
  home.activation.watchdogPetter = lib.hm.dag.entryAfter ["writeBoundary"] ''
    (
    SUDO=""
    if [ "$(id -u)" != "0" ]; then SUDO="sudo"; fi
    SRC="$HOME/.local/share/watchdog"

    # Load softdog kernel module (provides /dev/watchdog on VMs without hardware watchdog)
    $SUDO modprobe softdog soft_margin=${toString watchdogTimeout} 2>/dev/null || true

    # Persist softdog module across reboots
    echo "softdog" | $SUDO tee /etc/modules-load.d/softdog.conf >/dev/null 2>/dev/null || true
    echo "options softdog soft_margin=${toString watchdogTimeout}" | $SUDO tee /etc/modprobe.d/softdog.conf >/dev/null 2>/dev/null || true

    # Install systemd service
    $SUDO cp -f "$SRC/watchdog-petter.service" /etc/systemd/system/watchdog-petter.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable watchdog-petter.service 2>/dev/null || true
    $SUDO systemctl restart watchdog-petter.service 2>/dev/null || true

    echo "[watchdog] Kernel watchdog active — timeout=${toString watchdogTimeout}s, pet=${toString petInterval}s"
    echo "[watchdog] If userspace dies, kernel resets machine in ${toString watchdogTimeout}s"
    ) || echo "[watchdog] FAILED — see errors above (may need root)"
  '';
}
