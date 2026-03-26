# System Protection — Watchdog + Dropbear Rescue SSH
# Disk swap, disk watchdog (escalating cleanup), Dropbear rescue SSH
#
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, rescuePort ? 2200, ... }:

let
  diskSwapMB = if ramMB < 2048 then 2048 else ramMB;
  dropbearBin = "${pkgs.dropbear}/bin/dropbear";
  dropbearKeyBin = "${pkgs.dropbear}/bin/dropbearkey";
in {
  home.packages = [ pkgs.dropbear ];

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

  # ── Disk watchdog ─────────────────────────────────────────────────────
  home.file.".local/share/system-protection/disk-watchdog.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      WARN=85; CRIT=90; EMERG=95

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Root: ''${USAGE}%"
      [ "$USAGE" -lt "$WARN" ] && exit 0

      echo "[disk-watchdog] WARNING — cleaning"
      find /tmp -type f -atime +2 -delete 2>/dev/null || true
      find /var/tmp -type f -atime +2 -delete 2>/dev/null || true
      journalctl --vacuum-size=100M 2>/dev/null || true
      if command -v docker >/dev/null 2>&1; then
        docker container prune -f 2>/dev/null || true
        docker image prune -f 2>/dev/null || true
        docker builder prune -f --keep-storage=1G 2>/dev/null || true
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$CRIT" ] && echo "[disk-watchdog] Resolved ''${USAGE}%" && exit 0

      echo "[disk-watchdog] Level 2 (''${USAGE}%)"
      journalctl --vacuum-size=50M 2>/dev/null || true
      command -v docker >/dev/null 2>&1 && docker image prune -af 2>/dev/null && docker volume prune -f 2>/dev/null || true
      command -v nix-collect-garbage >/dev/null 2>&1 && nix-collect-garbage --delete-older-than 3d 2>/dev/null || true

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$EMERG" ] && echo "[disk-watchdog] Resolved ''${USAGE}%" && exit 0

      echo "[disk-watchdog] CRITICAL (''${USAGE}%)"
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
  # Feeds /dev/watchdog to prevent hardware reset, auto-heals containers,
  # restarts Docker if hung. Grace period: 12 failures × 5s = 60s before restart.
  home.file.".local/share/system-protection/watchdog-petter.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      exec 3>/dev/watchdog
      DOCKER_FAIL=0
      DOCKER_FAIL_THRESHOLD=120
      CTR_RESTART_TRACK=""
      HOSTNAME=$(hostname -s)
      LOG=/var/log/watchdog-petter.log
      NTFY="http://10.0.0.1:8090/watchdog-dropbear"

      sysinfo() {
        MEM=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
        LOAD=$(cut -d" " -f1-3 /proc/loadavg 2>/dev/null || echo "?")
        DISK=$(df / 2>/dev/null | awk 'NR==2 {print $5}' || echo "?")
        CTRS=$(docker ps -q 2>/dev/null | wc -l || echo "?")
        echo "mem=''${MEM}MB load=$LOAD disk=$DISK ctrs=$CTRS"
      }
      log()  { echo "$(date -Is) [$HOSTNAME] [watchdog] $1 | $(sysinfo)" >> "$LOG" 2>/dev/null; }
      ntfy() { curl -sf --max-time 3 -X POST "$NTFY" -H "Title: [$HOSTNAME] $2" -H "Priority: $1" -H "Tags: $4" -d "$3 | $(sysinfo)" 2>/dev/null || true; }

      CYCLE=0
      while true; do
        # Kernel liveness
        if ! [ -f /proc/loadavg ]; then
          log "FATAL: /proc unreadable"
          ntfy 5 "KERNEL FROZEN" "/proc unreadable — reset in 15s" "rotating_light,skull"
          exit 1
        fi

        # Docker liveness (60s grace period before restart)
        if ! docker info >/dev/null 2>&1; then
          DOCKER_FAIL=$((DOCKER_FAIL + 1))
          log "Docker not responding (fail $DOCKER_FAIL/$DOCKER_FAIL_THRESHOLD)"
          if [ "$DOCKER_FAIL" -ge "$DOCKER_FAIL_THRESHOLD" ]; then
            log "Restarting Docker daemon"
            ntfy 4 "Docker restart" "Docker hung ($DOCKER_FAIL failures) — restarting" "warning,whale"
            systemctl restart docker 2>/dev/null || true
            DOCKER_FAIL=0
          fi
          echo V >&3
          sleep 5
          continue
        fi
        DOCKER_FAIL=0

        # Restart crash-looping containers
        for ctr in $(docker ps -a --filter status=restarting --format "{{.Names}}" 2>/dev/null); do
          PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true)
          if [ "$PREV" -lt 2 ]; then
            log "Restarting crash-looping: $ctr"
            ntfy 3 "Container restart" "$ctr crash-looping" "warning,package"
            docker restart "$ctr" --time 10 2>/dev/null || true
            CTR_RESTART_TRACK="$CTR_RESTART_TRACK
      $ctr"
          fi
        done

        # Restart unhealthy containers
        for ctr in $(docker ps --filter health=unhealthy --format "{{.Names}}" 2>/dev/null); do
          PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true)
          if [ "$PREV" -lt 1 ]; then
            log "Restarting unhealthy: $ctr"
            ntfy 3 "Container unhealthy" "$ctr unhealthy" "warning,heartpulse"
            docker restart "$ctr" --time 10 2>/dev/null || true
            CTR_RESTART_TRACK="$CTR_RESTART_TRACK
      $ctr"
          fi
        done

        # Low memory prune
        MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 9999)
        if [ "$MEM_AVAIL" -lt 50 ]; then
          log "Low memory: ''${MEM_AVAIL}MB"
          ntfy 4 "Low memory" "''${MEM_AVAIL}MB available" "warning,brain"
          docker system prune -f 2>/dev/null || true
        fi

        CYCLE=$((CYCLE + 1))
        if [ "$CYCLE" -ge 10 ]; then
          CTR_RESTART_TRACK=""
          CYCLE=0
        fi

        echo V >&3
        sleep 5
      done
    '';
  };

  home.file.".local/share/system-protection/watchdog-petter.service".text = ''
    [Unit]
    Description=Kernel Watchdog Petter — auto-heals containers, resets if kernel frozen
    After=docker.service
    [Service]
    Type=simple
    ExecStart=/opt/scripts/watchdog-petter.sh
    OOMScoreAdjust=-999
    MemoryMax=10M
    MemoryMin=5M
    CPUWeight=10000
    Restart=always
    RestartSec=2
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  # ── Rescue SSH (Dropbear) ─────────────────────────────────────────────
  home.file.".local/share/system-protection/rescue-ssh.service".text = ''
    [Unit]
    Description=Rescue SSH (Dropbear on port ${toString rescuePort}) — UNTOUCHABLE
    After=network.target
    Before=docker.service
    [Service]
    Slice=connectivity.slice
    Type=simple
    ExecStartPre=/opt/scripts/rescue-ssh-setup.sh
    ExecStart=${dropbearBin} -F -E -p ${toString rescuePort} -r /etc/dropbear/dropbear_ed25519_host_key
    Restart=always
    RestartSec=2
    OOMScoreAdjust=-1000
    OOMPolicy=continue
    MemoryMin=20M
    MemoryMax=30M
    MemoryHigh=25M
    CPUSchedulingPolicy=fifo
    CPUSchedulingPriority=1
    IOSchedulingClass=realtime
    IOSchedulingPriority=0
    Nice=-20
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/rescue-ssh-setup.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      mkdir -p /etc/dropbear
      if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
        ${dropbearKeyBin} -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
        echo "[rescue-ssh] Generated ed25519 host key"
      fi
      echo "[rescue-ssh] Ready on port ${toString rescuePort}"
    '';
  };

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installWatchdogDropbear = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[watchdog-dropbear] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[watchdog-dropbear] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts /etc/dropbear
    $SUDO cp -f "$SRC/disk-swap.sh" /opt/scripts/disk-swap.sh
    $SUDO cp -f "$SRC/disk-watchdog.sh" /opt/scripts/disk-watchdog.sh
    $SUDO cp -f "$SRC/rescue-ssh-setup.sh" /opt/scripts/rescue-ssh-setup.sh
    $SUDO cp -f "$SRC/watchdog-petter.sh" /opt/scripts/watchdog-petter.sh
    $SUDO chmod +x /opt/scripts/disk-swap.sh /opt/scripts/disk-watchdog.sh /opt/scripts/rescue-ssh-setup.sh /opt/scripts/watchdog-petter.sh
    $SUDO cp -f "$SRC/disk-swap.service" /etc/systemd/system/disk-swap.service
    $SUDO cp -f "$SRC/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
    $SUDO cp -f "$SRC/disk-watchdog.timer" /etc/systemd/system/disk-watchdog.timer
    $SUDO cp -f "$SRC/rescue-ssh.service" /etc/systemd/system/rescue-ssh.service
    $SUDO cp -f "$SRC/watchdog-petter.service" /etc/systemd/system/watchdog-petter.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable disk-swap.service disk-watchdog.timer rescue-ssh.service watchdog-petter.service 2>/dev/null || true
    $SUDO systemctl start disk-swap.service 2>/dev/null || true
    $SUDO systemctl start disk-watchdog.timer 2>/dev/null || true
    $SUDO systemctl restart rescue-ssh.service 2>/dev/null || true
    $SUDO systemctl restart watchdog-petter.service 2>/dev/null || true

    echo "[watchdog-dropbear] deployed: disk-swap=${toString diskSwapMB}MB rescue-ssh=port${toString rescuePort} watchdog-petter=10min-grace"
    ) || echo "[watchdog-dropbear] FAILED — activation continues"
  '';
}
