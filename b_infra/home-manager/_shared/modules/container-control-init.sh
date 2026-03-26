#!/bin/bash
# Container Init — Docker lifecycle + sequential container startup
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/home-manager/_shared/modules/container-control-init.sh
set -uo pipefail

# ── PATH: ensure nix binaries available (systemd doesn't have them) ───
for p in /home/*/nix-profile/bin /home/*/.nix-profile/bin /nix/var/nix/profiles/default/bin; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

# ── Config: read from cloud-data JSON if available, else defaults ─────
CLOUD_DATA="/opt/scripts/cloud-data-home-manager.json"
if [ -f "$CLOUD_DATA" ] && command -v jq >/dev/null 2>&1; then
  NTFY_BASE=$(jq -r '.monitoring.ntfy_base // "https://rss.diegonmarcos.com"' "$CLOUD_DATA")
  DNS_PRIMARY=$(jq -r '.dns.primary // "10.0.0.1"' "$CLOUD_DATA")
  DNS_FALLBACK=$(jq -r '.dns.fallback // "1.1.1.1"' "$CLOUD_DATA")
else
  NTFY_BASE="https://rss.diegonmarcos.com"
  DNS_PRIMARY="10.0.0.1"
  DNS_FALLBACK="1.1.1.1"
fi

HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
LOG_TAG="container-init"
LOG_FILE="/var/log/container-init.log"
BOOT_JSON="/var/log/container-init-boot.json"
CONTAINERS_DIR="/opt/containers"
NTFY_URL="${NTFY_BASE}/container-init"
DOCKER_TIMEOUT=60
HEALTH_TIMEOUT=120
HEALTH_INTERVAL=5
START_DELAY=3
BOOT_START=$(date +%s)
_LAST_STEP=$BOOT_START

# ── Perf + Logging (flush every line to journal) ─────────────────────
log() {
  local now=$(date +%s)
  local elapsed=$(( now - BOOT_START ))
  local step_s=$(( now - _LAST_STEP ))
  _LAST_STEP=$now
  local msg="[$LOG_TAG] +${elapsed}s (+${step_s}s) $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

ntfy() {
  local title="$1" body="$2" priority="${3:-default}" tags="${4:-whale}"
  curl -sf -X POST "$NTFY_URL" \
    -H "Title: [$HOSTNAME] $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$body" >/dev/null 2>&1 || true
}

# ── Phase 0: Docker daemon startup ────────────────────────────────────
log "═══ PHASE 0: Docker daemon ═══"
log "PATH=$PATH"
log "mem=$(free -m 2>/dev/null | awk '/Mem:/{printf "%dMB used, %dMB free, %dMB total", $3, $4, $2}'))"
DOCKER_OK=false

if docker info >/dev/null 2>&1; then
  log "Docker already running"
  DOCKER_OK=true
else
  log "Starting Docker daemon..."
  systemctl start docker 2>&1 | while IFS= read -r line; do log "  dockerd: $line"; done

  for i in $(seq 1 "$DOCKER_TIMEOUT"); do
    if docker info >/dev/null 2>&1; then
      DOCKER_OK=true
      log "Docker healthy after ${i}s"
      break
    fi
    if ! systemctl is-active docker >/dev/null 2>&1; then
      log "FATAL: Docker process died during startup"
      break
    fi
    log "  waiting for dockerd... (${i}/${DOCKER_TIMEOUT}s) mem=$(free -m 2>/dev/null | awk '/Mem:/{print $4}')MB free"
    sleep 1
  done
fi

if [ "$DOCKER_OK" = false ]; then
  log "FATAL: Docker failed to become healthy after ${DOCKER_TIMEOUT}s"
  ntfy "Docker FAILED" "Docker daemon did not start on $HOSTNAME after ${DOCKER_TIMEOUT}s." "urgent" "rotating_light"
  echo "{\"boot\":\"$(date -Iseconds)\",\"docker\":\"failed\",\"containers\":[],\"total_s\":0}" > "$BOOT_JSON" 2>/dev/null || true
  exit 1
fi

DOCKER_ELAPSED=$(( $(date +%s) - BOOT_START ))
log "Docker ready (${DOCKER_ELAPSED}s)"

# ── Phase 1: Discover compose projects ────────────────────────────────
log "═══ PHASE 1: Discover compose projects ═══"
PROJECTS=""
for dir in "$CONTAINERS_DIR"/*/; do
  [ -f "$dir/docker-compose.yml" ] && PROJECTS="$PROJECTS $dir"
done
for dir in /opt/*/; do
  [ "$dir" = "$CONTAINERS_DIR/" ] && continue
  [ "$dir" = "/opt/scripts/" ] && continue
  [ "$dir" = "/opt/ssh-keys/" ] && continue
  [ -f "$dir/docker-compose.yml" ] && PROJECTS="$PROJECTS $dir"
done

PROJECT_COUNT=$(echo $PROJECTS | wc -w)
log "Found $PROJECT_COUNT compose projects"

# ── Phase 2: Sequential startup (--no-build!) ─────────────────────────
log "═══ PHASE 2: Sequential startup ═══"
STARTED=0
FAILED=0
BOOT_RESULTS=""

for dir in $PROJECTS; do
  svc=$(basename "$dir")
  svc_start=$(date +%s)
  log "  [$svc] starting..."
  log "  [$svc] mem=$(free -m 2>/dev/null | awk '/Mem:/{print $4}')MB free"

  if (cd "$dir" && docker compose up -d --no-build 2>&1 | while IFS= read -r line; do log "    $line"; done); then
    svc_s=$(( $(date +%s) - svc_start ))
    log "  [$svc] started (${svc_s}s)"
    STARTED=$((STARTED + 1))
    BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":true},"
  else
    svc_s=$(( $(date +%s) - svc_start ))
    log "  [$svc] FAILED (${svc_s}s)"
    FAILED=$((FAILED + 1))
    BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":false},"
  fi

  sleep "$START_DELAY"
done

STARTUP_ELAPSED=$(( $(date +%s) - BOOT_START ))
log "Startup complete: $STARTED ok, $FAILED failed (${STARTUP_ELAPSED}s)"

# ── Phase 3: Health verification ──────────────────────────────────────
log "═══ PHASE 3: Health verification ═══"
HEALTH_START=$(date +%s)
UNHEALTHY=""
HEALTHY_COUNT=0
TOTAL_CONTAINERS=0
RESTARTED=0

sleep 10

while IFS= read -r container; do
  [ -z "$container" ] && continue
  TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 1))
  name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/^\///')
  has_hc=$(docker inspect --format='{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$container" 2>/dev/null || echo "no")

  if [ "$has_hc" = "yes" ]; then
    health="starting"
    waited=0
    while [ "$health" = "starting" ] && [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
      health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
      [ "$health" = "starting" ] && sleep "$HEALTH_INTERVAL" && waited=$((waited + HEALTH_INTERVAL))
    done

    if [ "$health" = "healthy" ]; then
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
      log "  $name: healthy"
    else
      log "  $name: UNHEALTHY ($health) — restarting..."
      docker restart "$container" >/dev/null 2>&1
      sleep 10
      health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
      RESTARTED=$((RESTARTED + 1))
      if [ "$health" = "healthy" ]; then
        log "  $name: healthy after restart"
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
      else
        log "  $name: STILL UNHEALTHY ($health)"
        UNHEALTHY="$UNHEALTHY $name"
      fi
    fi
  else
    state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
    if [ "$state" = "running" ]; then
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
      log "  $name: NOT RUNNING ($state)"
      UNHEALTHY="$UNHEALTHY $name"
    fi
  fi
done < <(docker ps -q 2>/dev/null)

HEALTH_S=$(( $(date +%s) - HEALTH_START ))
TOTAL_ELAPSED=$(( $(date +%s) - BOOT_START ))
log "Health: $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy, $RESTARTED restarted (${HEALTH_S}s)"

# ── Phase 4: Report ───────────────────────────────────────────────────
log "═══ PHASE 4: Report ═══"

cat > "$BOOT_JSON" 2>/dev/null <<EOF || true
{"boot":"$(date -Iseconds)","hostname":"$HOSTNAME","docker_s":$DOCKER_ELAPSED,"projects":$PROJECT_COUNT,"started":$STARTED,"failed":$FAILED,"containers":$TOTAL_CONTAINERS,"healthy":$HEALTHY_COUNT,"restarted":$RESTARTED,"total_s":$TOTAL_ELAPSED,"detail":[${BOOT_RESULTS%,}]}
EOF

if [ -n "$UNHEALTHY" ]; then
  ntfy "Boot: UNHEALTHY:$UNHEALTHY" "Docker:${DOCKER_ELAPSED}s | $STARTED/$PROJECT_COUNT projects | $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | ${TOTAL_ELAPSED}s" "high" "warning"
elif [ "$FAILED" -gt 0 ]; then
  ntfy "Boot: $FAILED failed" "Docker:${DOCKER_ELAPSED}s | $STARTED/$PROJECT_COUNT projects | $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | ${TOTAL_ELAPSED}s" "high" "warning"
else
  ntfy "Boot OK: $PROJECT_COUNT projects" "Docker:${DOCKER_ELAPSED}s | $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | ${TOTAL_ELAPSED}s" "default" "white_check_mark"
fi

log "═══ CONTAINER INIT COMPLETE (${TOTAL_ELAPSED}s) ═══"
