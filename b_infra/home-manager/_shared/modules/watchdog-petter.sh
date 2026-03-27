#!/bin/sh
# Watchdog Petter — kernel watchdog + container auto-healer
# Rich telemetry: mem, swap, PSI, top procs, disk, containers every 30s
# POSIX sh — no bash required
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/home-manager/_shared/modules/watchdog-petter.sh

# Hardware watchdog DISABLED — CPUQuota throttling causes missed pets → VM reset
# TODO: re-enable once we confirm VMs are stable without it
# exec 3>/dev/watchdog 2>/dev/null || echo "[watchdog] WARNING: /dev/watchdog not available"
WD_ENABLED=0
DOCKER_FAIL=0
DOCKER_FAIL_THRESHOLD=120
CTR_RESTART_TRACK=""
HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
LOG=/var/log/watchdog-petter.log
NTFY="http://10.0.0.1:8090/watchdog-dropbear"
BOOT_TIME=$(date -Is)
CYCLE=0
TICK=0

# ── Rich telemetry ──────────────────────────────────────────────
sysinfo_full() {
  # Memory
  MEM_TOTAL=$(awk '/MemTotal/    {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  MEM_AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
  MEM_PCT=$((MEM_USED * 100 / (MEM_TOTAL + 1)))
  BUFCACHE=$(awk '/Buffers/{b=$2} /^Cached/{c=$2} END{print int((b+c)/1024)}' /proc/meminfo 2>/dev/null)

  # Swap
  SWAP_TOTAL=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  SWAP_USED=$(awk '/SwapFree/  {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  SWAP_USED=$((SWAP_TOTAL - SWAP_USED))

  # PSI (pressure stall info)
  MEM_PSI="N/A"; CPU_PSI="N/A"; IO_PSI="N/A"
  [ -f /proc/pressure/memory ] && MEM_PSI=$(awk '/some/{print $2}' /proc/pressure/memory 2>/dev/null | head -1)
  [ -f /proc/pressure/cpu ]    && CPU_PSI=$(awk '/some/{print $2}' /proc/pressure/cpu 2>/dev/null | head -1)
  [ -f /proc/pressure/io ]     && IO_PSI=$(awk '/some/{print $2}' /proc/pressure/io 2>/dev/null | head -1)

  # Load + uptime
  LOAD=$(cut -d" " -f1-3 /proc/loadavg 2>/dev/null)
  PROCS=$(cut -d" " -f4 /proc/loadavg 2>/dev/null)
  UPTIME=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd%dh%dm", d, h, m}' /proc/uptime 2>/dev/null)

  # Disk
  DISK=$(df / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')

  # Docker containers
  CTRS=0; CTRS_HEALTHY=0; CTRS_UNHEALTHY=0; CTRS_RESTARTING=0
  if docker info >/dev/null 2>&1; then
    CTRS=$(docker ps -q 2>/dev/null | wc -l)
    CTRS_HEALTHY=$(docker ps --filter health=healthy -q 2>/dev/null | wc -l)
    CTRS_UNHEALTHY=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
    CTRS_RESTARTING=$(docker ps -a --filter status=restarting -q 2>/dev/null | wc -l)
  fi

  # Top 5 procs by RSS
  TOP_PROCS=$(ps aux --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=6{printf "%s(%s%%/%dMB) ", $11, $4, $6/1024}')

  printf "mem=%dM/%dM(%d%%) buf+cache=%dM swap=%dM/%dM | load=%s procs=%s up=%s | psi:mem=%s cpu=%s io=%s | disk=%s | ctrs=%d(ok=%d bad=%d loop=%d) | top: %s" \
    "$MEM_USED" "$MEM_TOTAL" "$MEM_PCT" "$BUFCACHE" "$SWAP_USED" "$SWAP_TOTAL" \
    "$LOAD" "$PROCS" "$UPTIME" "$MEM_PSI" "$CPU_PSI" "$IO_PSI" \
    "$DISK" "$CTRS" "$CTRS_HEALTHY" "$CTRS_UNHEALTHY" "$CTRS_RESTARTING" \
    "$TOP_PROCS"
}

log() {
  INFO=$(sysinfo_full)
  MSG="$(date -Is) [$HOSTNAME] [watchdog] $1 | $INFO"
  # Force sync to disk — must survive kernel freeze
  printf '%s\n' "$MSG" >> "$LOG" 2>/dev/null && sync "$LOG" 2>/dev/null
  printf '%s\n' "$MSG"
}
ntfy() { curl -sf --max-time 3 -X POST "$NTFY" -H "Title: [$HOSTNAME] $2" -H "Priority: $1" -H "Tags: $4" -d "$3 | $(sysinfo_full)" 2>/dev/null || true; }

log "BOOT: watchdog-petter started (threshold=$DOCKER_FAIL_THRESHOLD)"

while true; do
  TICK=$((TICK + 1))

  # Kernel liveness
  if ! [ -f /proc/loadavg ]; then
    log "FATAL: /proc unreadable"
    ntfy 5 "KERNEL FROZEN" "/proc unreadable — reset in 15s" "rotating_light,skull"
    exit 1
  fi

  # Periodic telemetry (every 6th cycle = 30s)
  if [ $((TICK % 6)) -eq 0 ]; then
    log "tick=$TICK"
  fi

  # Docker liveness
  if ! docker info >/dev/null 2>&1; then
    DOCKER_FAIL=$((DOCKER_FAIL + 1))
    # Log every 12th failure (60s) to avoid spam
    if [ $((DOCKER_FAIL % 12)) -eq 1 ]; then
      log "Docker not responding (fail $DOCKER_FAIL/$DOCKER_FAIL_THRESHOLD)"
    fi
    if [ "$DOCKER_FAIL" -ge "$DOCKER_FAIL_THRESHOLD" ]; then
      log "Restarting Docker daemon"
      ntfy 4 "Docker restart" "Docker hung ($DOCKER_FAIL failures) — restarting" "warning,whale"
      systemctl restart docker 2>/dev/null || true
      DOCKER_FAIL=0
    fi
    [ "$WD_ENABLED" = "1" ] && echo V >&3 2>/dev/null
    sleep 5
    continue
  fi
  [ "$DOCKER_FAIL" -gt 0 ] && log "Docker recovered after $DOCKER_FAIL failures"
  DOCKER_FAIL=0

  # Restart crash-looping containers
  for ctr in $(docker ps -a --filter status=restarting --format "{{.Names}}" 2>/dev/null); do
    PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true)
    if [ "$PREV" -lt 2 ]; then
      log "ACTION: Restarting crash-looping: $ctr"
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
      log "ACTION: Restarting unhealthy: $ctr"
      ntfy 3 "Container unhealthy" "$ctr unhealthy" "warning,heartpulse"
      docker restart "$ctr" --time 10 2>/dev/null || true
      CTR_RESTART_TRACK="$CTR_RESTART_TRACK
$ctr"
    fi
  done

  # Low memory prune
  MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 9999)
  if [ "$MEM_AVAIL" -lt 50 ]; then
    log "ALERT: Low memory ${MEM_AVAIL}MB — pruning Docker"
    ntfy 4 "Low memory" "${MEM_AVAIL}MB available" "warning,brain"
    docker system prune -f 2>/dev/null || true
  fi

  CYCLE=$((CYCLE + 1))
  if [ "$CYCLE" -ge 10 ]; then
    CTR_RESTART_TRACK=""
    CYCLE=0
  fi

  echo V >&3 2>/dev/null
  sleep 5
done
