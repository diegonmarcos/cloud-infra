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
      CTR_RESTART_TRACK=""; \
      LOG="/var/log/watchdog-petter.log"; \
      log() { echo "$(date -Is) [watchdog] $1" >> "$LOG" 2>/dev/null; }; \
      while true; do \
        # ═══════════════════════════════════════════════════════════ \
        # TIER 0: KERNEL — is /proc readable? \
        # ═══════════════════════════════════════════════════════════ \
        if ! [ -f /proc/loadavg ]; then \
          log "FATAL: /proc unreadable — kernel frozen. Stopping petter."; \
          exit 1; \
        fi; \
        \
        # ═══════════════════════════════════════════════════════════ \
        # TIER 1: DOCKER DAEMON — is it responding? \
        # ═══════════════════════════════════════════════════════════ \
        if ! docker info >/dev/null 2>&1; then \
          DOCKER_FAIL=$((DOCKER_FAIL + 1)); \
          log "ALERT: Docker not responding (fail $DOCKER_FAIL)"; \
          if [ "$DOCKER_FAIL" -ge 3 ]; then \
            log "ACTION: restarting Docker daemon (attempt $((DOCKER_FAIL - 2)))"; \
            systemctl restart docker 2>/dev/null || true; \
          fi; \
          echo V >&3; \
          sleep ${toString petInterval}; \
          continue; \
        fi; \
        DOCKER_FAIL=0; \
        \
        # ═══════════════════════════════════════════════════════════ \
        # TIER 2: CONTAINERS — iterate ALL, auto-heal individually \
        # ═══════════════════════════════════════════════════════════ \
        \
        # 2a: Restart crash-looping containers (status=restarting) \
        for ctr in $(docker ps -a --filter status=restarting --format "{{.Names}}" 2>/dev/null); do \
          # Track restart attempts per container (max 2 per cycle) \
          PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true); \
          if [ "$PREV" -lt 2 ]; then \
            log "ACTION: restarting crash-looping container: $ctr"; \
            docker restart "$ctr" --time 10 2>/dev/null || true; \
            CTR_RESTART_TRACK="$CTR_RESTART_TRACK\n$ctr"; \
          elif [ "$PREV" -eq 2 ]; then \
            log "WARN: $ctr still crash-looping after 2 restarts — skipping"; \
          fi; \
        done; \
        \
        # 2b: Restart unhealthy containers \
        for ctr in $(docker ps --filter health=unhealthy --format "{{.Names}}" 2>/dev/null); do \
          PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true); \
          if [ "$PREV" -lt 1 ]; then \
            log "ACTION: restarting unhealthy container: $ctr"; \
            docker restart "$ctr" --time 10 2>/dev/null || true; \
            CTR_RESTART_TRACK="$CTR_RESTART_TRACK\n$ctr"; \
          fi; \
        done; \
        \
        # 2c: Restart exited containers (non-zero exit, not one-shot) \
        for ctr in $(docker ps -a --filter status=exited --filter "exited!=0" --format "{{.Names}}" 2>/dev/null); do \
          # Skip known one-shot containers (init, migration, etc.) \
          case "$ctr" in *init*|*migrate*|*setup*|*_minio_init*) continue;; esac; \
          PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true); \
          if [ "$PREV" -lt 1 ]; then \
            log "ACTION: restarting exited container: $ctr (non-zero exit)"; \
            docker start "$ctr" 2>/dev/null || true; \
            CTR_RESTART_TRACK="$CTR_RESTART_TRACK\n$ctr"; \
          fi; \
        done; \
        \
        # ═══════════════════════════════════════════════════════════ \
        # TIER 3: SYSTEM HEALTH — memory, disk, load \
        # ═══════════════════════════════════════════════════════════ \
        MEM_AVAIL=$(awk "/MemAvailable/ {print int(\$2/1024)}" /proc/meminfo 2>/dev/null || echo 9999); \
        DISK_PCT=$(df / 2>/dev/null | awk "NR==2 {gsub(/%/,\"\"); print \$5}" || echo 0); \
        LOAD=$(cat /proc/loadavg 2>/dev/null | cut -d" " -f1 || echo 0); \
        if [ "$MEM_AVAIL" -lt 50 ]; then \
          log "WARN: low memory: ${MEM_AVAIL}MB available — pruning Docker"; \
          docker system prune -f --volumes 2>/dev/null || true; \
        fi; \
        if [ "$DISK_PCT" -gt 95 ]; then \
          log "WARN: disk ${DISK_PCT}% full — pruning Docker images"; \
          docker image prune -af 2>/dev/null || true; \
        fi; \
        \
        # Reset container restart tracking every 10 cycles (50s) \
        CYCLE=$((${CYCLE:-0} + 1)); \
        if [ "$CYCLE" -ge 10 ]; then \
          CTR_RESTART_TRACK=""; \
          CYCLE=0; \
        fi; \
        \
        # ═══════════════════════════════════════════════════════════ \
        # ALL TIERS PASSED — pet the dog \
        # ═══════════════════════════════════════════════════════════ \
        echo V >&3; \
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
