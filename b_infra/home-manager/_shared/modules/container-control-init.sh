#!/bin/bash
# Container Init — Docker lifecycle + data-driven sequential container startup
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/home-manager/_shared/modules/container-control-init.sh
#
# Data-driven from container-init.json (identity + config)
# Clones/pulls cloud-data for declared container manifests
# Generates drift report comparing declared vs actual
#
# Phases:
#   0: Docker daemon startup
#   1: Cloud-data sync (git clone/pull)
#   2: Drift detection (declared vs actual containers)
#   3: Image pull (sequential, ionice/nice)
#   4: Sequential container startup (docker start, fallback compose)
#   5: Health verification + logs
#   6: Report + ntfy
set -uo pipefail

# ── Sudo: escalate if not root ────────────────────────────────────────
if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@"
fi

# ── PATH: ensure nix binaries available (systemd doesn't have them) ───
for p in /home/*/nix-profile/bin /home/*/.nix-profile/bin /nix/var/nix/profiles/default/bin; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

# ── Config: read from container-init.json ──────────────────────────────
CONFIG="/opt/scripts/container-init.json"
if [ ! -f "$CONFIG" ]; then
  echo "[container-init] FATAL: $CONFIG not found" >&2
  exit 1
fi

# Parse config (jq required)
if ! command -v jq >/dev/null 2>&1; then
  echo "[container-init] FATAL: jq not found" >&2
  exit 1
fi

VM_ALIAS=$(jq -r '.vm_alias' "$CONFIG")
VM_ID=$(jq -r '.vm_id // ""' "$CONFIG")
CLOUD_DATA_REPO=$(jq -r '.cloud_data_repo // "https://github.com/diegonmarcos/cloud-data.git"' "$CONFIG")
CLOUD_DATA_DIR=$(jq -r '.cloud_data_dir // "/home/diego/git/cloud-data"' "$CONFIG")
CONTAINERS_DIR=$(jq -r '.containers_dir // "/opt/containers"' "$CONFIG")
NTFY_BASE=$(jq -r '.ntfy_base // "https://rss.diegonmarcos.com"' "$CONFIG")
NTFY_TOPIC=$(jq -r '.ntfy_topic // "container-init"' "$CONFIG")
DOCKER_TIMEOUT=$(jq -r '.docker_timeout // 60' "$CONFIG")
START_DELAY=$(jq -r '.start_delay // 5' "$CONFIG")
PULL_NICE=$(jq -r '.pull_nice // 19' "$CONFIG")
PULL_IONICE=$(jq -r '.pull_ionice // 3' "$CONFIG")
GIT_USER=$(jq -r '.git_user // "diego"' "$CONFIG")

HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
NTFY_URL="${NTFY_BASE}/${NTFY_TOPIC}"
BOOT_START=$(date +%s)
_LAST_STEP=$BOOT_START
BOOT_JSON="/var/log/container-init-boot.json"
DRIFT_JSON="/var/log/container-init-drift.json"
LOG_FILE="/var/log/container-init.log"

# ── Logging (journal + file + console) ─────────────────────────────────
log() {
  local now=$(date +%s)
  local elapsed=$(( now - BOOT_START ))
  local step_s=$(( now - _LAST_STEP ))
  _LAST_STEP=$now
  local msg="[container-init] +${elapsed}s (+${step_s}s) $*"
  echo "$msg" | systemd-cat -t container-init -p info 2>/dev/null || true
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_err() {
  local msg="[container-init] ERROR: $*"
  echo "$msg" | systemd-cat -t container-init -p err 2>/dev/null || true
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

mem_free() { free -m 2>/dev/null | awk '/Mem:/{print $4}'; }

# ══════════════════════════════════════════════════════════════════════════
# PHASE 0: Docker daemon startup
# ══════════════════════════════════════════════════════════════════════════
log "═══ PHASE 0: Docker daemon ═══"
log "vm=$VM_ALIAS hostname=$HOSTNAME mem=$(mem_free)MB free"
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
      log_err "Docker process died during startup"
      break
    fi
    [ $((i % 10)) -eq 0 ] && log "  waiting for dockerd... (${i}/${DOCKER_TIMEOUT}s) mem=$(mem_free)MB free"
    sleep 1
  done
fi

if [ "$DOCKER_OK" = false ]; then
  log_err "FATAL: Docker failed after ${DOCKER_TIMEOUT}s"
  ntfy "Docker FAILED" "Docker daemon did not start on $HOSTNAME after ${DOCKER_TIMEOUT}s" "urgent" "rotating_light"
  echo "{\"boot\":\"$(date -Iseconds)\",\"vm\":\"$VM_ALIAS\",\"docker\":\"failed\"}" > "$BOOT_JSON" 2>/dev/null || true
  exit 1
fi

DOCKER_ELAPSED=$(( $(date +%s) - BOOT_START ))
log "Docker ready (${DOCKER_ELAPSED}s)"

# ══════════════════════════════════════════════════════════════════════════
# PHASE 0.5: Home-Manager self-update (pull + activate latest HM image)
# ══════════════════════════════════════════════════════════════════════════
HM_DELIVERY=$(echo "$CONFIG" | jq -r '.hm_delivery // "nix-copy"')
HM_IMAGE=$(echo "$CONFIG" | jq -r '.hm_image // ""')
HM_USER=$(echo "$CONFIG" | jq -r '.hm_user // "diego"')
HM_CONFIG=$(echo "$CONFIG" | jq -r '.hm_config // ""')

if [ "$HM_DELIVERY" = "docker" ] && [ -n "$HM_IMAGE" ]; then
  log "═══ PHASE 0.5: Home-Manager self-update ═══"
  log "  delivery=$HM_DELIVERY image=$HM_IMAGE user=$HM_USER"

  # Pull latest HM image
  OLD_ID=$(docker inspect --format '{{.Id}}' "$HM_IMAGE" 2>/dev/null || echo "none")
  if ionice -c3 nice -n19 docker pull "$HM_IMAGE" >/dev/null 2>&1; then
    NEW_ID=$(docker inspect --format '{{.Id}}' "$HM_IMAGE" 2>/dev/null || echo "none")
    if [ "$OLD_ID" != "$NEW_ID" ]; then
      log "  HM image updated — activating..."
      # Extract and activate: run the HM image which copies closure + switches
      HM_HOME=$(eval echo "~$HM_USER")
      docker run --rm \
        -v /nix:/nix \
        -v "$HM_HOME:$HM_HOME" \
        -v /etc:/etc \
        -v /tmp:/tmp \
        "$HM_IMAGE" 2>&1 | while IFS= read -r line; do log "    $line"; done
      log "  HM activated from $HM_IMAGE"
    else
      log "  HM image unchanged — skipping activation"
    fi
  else
    log "  WARNING: HM image pull failed — using existing config"
  fi
else
  log "═══ PHASE 0.5: HM self-update skipped (delivery=$HM_DELIVERY) ═══"
fi

# ══════════════════════════════════════════════════════════════════════════
# PHASE 1: Cloud-data sync (git clone or pull, remote always wins)
# ══════════════════════════════════════════════════════════════════════════
log "═══ PHASE 1: Cloud-data sync ═══"
CLOUD_DATA_OK=false

# Ensure parent dir exists
mkdir -p "$(dirname "$CLOUD_DATA_DIR")" 2>/dev/null || true

if [ -d "$CLOUD_DATA_DIR/.git" ]; then
  log "Pulling cloud-data (remote wins)..."
  if (cd "$CLOUD_DATA_DIR" && git fetch origin main 2>&1 && git reset --hard origin/main 2>&1) | while IFS= read -r line; do log "  git: $line"; done; then
    CLOUD_DATA_OK=true
    log "cloud-data updated"
  else
    log_err "git pull failed — using cached data"
    CLOUD_DATA_OK=true  # stale but usable
  fi
else
  log "Cloning cloud-data..."
  if git clone --depth 1 "$CLOUD_DATA_REPO" "$CLOUD_DATA_DIR" 2>&1 | while IFS= read -r line; do log "  git: $line"; done; then
    CLOUD_DATA_OK=true
    log "cloud-data cloned"
  else
    log_err "git clone failed — cannot determine declared containers"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════
# PHASE 2: Drift detection (declared vs actual containers)
# ══════════════════════════════════════════════════════════════════════════
log "═══ PHASE 2: Drift detection ═══"

# Find VM-specific containers manifest from cloud-data
CONTAINERS_JSON=""
for pattern in "cloud-data-containers-${VM_ALIAS}.json" "cloud-data-containers-*.json"; do
  MATCH=$(find "$CLOUD_DATA_DIR" -maxdepth 1 -name "$pattern" 2>/dev/null | head -1)
  [ -n "$MATCH" ] && CONTAINERS_JSON="$MATCH" && break
done

# Copy alongside container-init.json for reference
if [ -n "$CONTAINERS_JSON" ]; then
  cp -f "$CONTAINERS_JSON" /opt/scripts/container-init-declared.json 2>/dev/null || true
  log "Declared containers: $CONTAINERS_JSON"
else
  log_err "No containers manifest found for vm=$VM_ALIAS"
fi

# Build declared list
DECLARED_SERVICES=""
DECLARED_IMAGES=""
DECLARED_COUNT=0
if [ -n "$CONTAINERS_JSON" ] && [ -f "$CONTAINERS_JSON" ]; then
  DECLARED_COUNT=$(jq '.services | length' "$CONTAINERS_JSON")
  DECLARED_SERVICES=$(jq -r '.services[].compose_path' "$CONTAINERS_JSON")
  DECLARED_IMAGES=$(jq -r '.services[].images[]' "$CONTAINERS_JSON" 2>/dev/null | sort -u)
  log "Declared: $DECLARED_COUNT services"
fi

# Build actual list (existing containers on this VM)
ACTUAL_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort)
ACTUAL_COUNT=$(echo "$ACTUAL_CONTAINERS" | grep -c . 2>/dev/null || echo 0)
log "Actual: $ACTUAL_COUNT containers"

# Generate drift report
DRIFT_MISSING=""
DRIFT_EXTRA=""
DRIFT_STOPPED=""

if [ -n "$CONTAINERS_JSON" ] && [ -f "$CONTAINERS_JSON" ]; then
  # Check each declared service
  while IFS= read -r svc_json; do
    svc_name=$(echo "$svc_json" | jq -r '.name')
    svc_path=$(echo "$svc_json" | jq -r '.compose_path')
    # Check if compose dir exists
    if [ ! -d "$svc_path" ]; then
      DRIFT_MISSING="$DRIFT_MISSING $svc_name(no-dir)"
      continue
    fi
    # Check if container exists
    if ! echo "$ACTUAL_CONTAINERS" | grep -q "^${svc_name}$"; then
      # Maybe container name differs from service name
      compose_containers=$(cd "$svc_path" 2>/dev/null && docker compose ps --format '{{.Names}}' 2>/dev/null || true)
      if [ -z "$compose_containers" ]; then
        DRIFT_MISSING="$DRIFT_MISSING $svc_name(no-container)"
      fi
    fi
  done < <(jq -c '.services[]' "$CONTAINERS_JSON" 2>/dev/null)

  # Check for stopped containers
  DRIFT_STOPPED=$(docker ps -a --filter "status=exited" --filter "status=created" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
fi

# Write drift JSON
jq -n \
  --arg vm "$VM_ALIAS" \
  --arg ts "$(date -Iseconds)" \
  --argjson declared "$DECLARED_COUNT" \
  --argjson actual "$ACTUAL_COUNT" \
  --arg missing "$(echo $DRIFT_MISSING | xargs)" \
  --arg stopped "$(echo $DRIFT_STOPPED | xargs)" \
  '{vm: $vm, timestamp: $ts, declared: $declared, actual: $actual, missing: $missing, stopped: $stopped}' \
  > "$DRIFT_JSON" 2>/dev/null || true

if [ -n "$DRIFT_MISSING" ]; then
  log "DRIFT: missing services:$DRIFT_MISSING"
fi
if [ -n "$DRIFT_STOPPED" ]; then
  log "DRIFT: stopped containers: $DRIFT_STOPPED"
fi
if [ -z "$DRIFT_MISSING" ] && [ -z "$DRIFT_STOPPED" ]; then
  log "No drift detected"
fi

# PHASE 3: REMOVED — image pull is build.sh ship's job, not container-init's.
# Images are already on disk from the last ship. docker-run.sh pulls if needed.

# ══════════════════════════════════════════════════════════════════════════
# PHASE 4: Sequential container startup — docker start ONLY (no compose)
# ══════════════════════════════════════════════════════════════════════════
log "═══ PHASE 4: Sequential startup ═══"
STARTED=0
FAILED=0
BOOT_RESULTS=""

# Start all existing containers one service at a time using docker start (no Go binary)
# If container doesn't exist, skip it — build.sh ship creates containers, not container-init
for dir in $DECLARED_SERVICES; do
  svc=$(basename "$dir")
  svc_start=$(date +%s)
  log "  [$svc] starting... mem=$(mem_free)MB free"

  # Get all container names for this service directory
  CONTAINERS=""
  for cid in $(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$dir" 2>/dev/null); do
    CONTAINERS="$CONTAINERS $cid"
  done
  # Fallback: match by container name containing service name
  if [ -z "$CONTAINERS" ]; then
    CONTAINERS=$(docker ps -aq --filter "name=$svc" 2>/dev/null || true)
  fi

  if [ -n "$CONTAINERS" ]; then
    if echo "$CONTAINERS" | xargs docker start 2>&1 | while IFS= read -r line; do log "    $line"; done; then
      svc_s=$(( $(date +%s) - svc_start ))
      log "  [$svc] started (${svc_s}s)"
      STARTED=$((STARTED + 1))
      BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":true,\"method\":\"start\"},"
    else
      svc_s=$(( $(date +%s) - svc_start ))
      log_err "  [$svc] FAILED (${svc_s}s)"
      FAILED=$((FAILED + 1))
      BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":false,\"method\":\"start\"},"
    fi
  elif [ -f "$dir/docker-run.sh" ]; then
    # No containers exist but docker-run.sh available — create them (no compose needed)
    log "  [$svc] no containers — using docker-run.sh"
    if (cd "$dir" && sh docker-run.sh 2>&1 | while IFS= read -r line; do log "    $line"; done); then
      svc_s=$(( $(date +%s) - svc_start ))
      log "  [$svc] created via docker-run.sh (${svc_s}s)"
      STARTED=$((STARTED + 1))
      BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":true,\"method\":\"docker-run\"},"
    else
      svc_s=$(( $(date +%s) - svc_start ))
      log_err "  [$svc] FAILED (${svc_s}s)"
      FAILED=$((FAILED + 1))
      BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":false,\"method\":\"docker-run\"},"
    fi
  else
    # Last resort: pull configs image from GHCR, extract, then run docker-run.sh
    CONFIGS_IMG="ghcr.io/diegonmarcos/${svc}-configs:latest"
    if docker pull "$CONFIGS_IMG" >/dev/null 2>&1; then
      log "  [$svc] pulled configs image — extracting"
      docker run --rm -v "$dir:/out" "$CONFIGS_IMG" 2>/dev/null
      if [ -f "$dir/docker-run.sh" ]; then
        if (cd "$dir" && sh docker-run.sh 2>&1 | while IFS= read -r line; do log "    $line"; done); then
          svc_s=$(( $(date +%s) - svc_start ))
          log "  [$svc] created via configs-image + docker-run.sh (${svc_s}s)"
          STARTED=$((STARTED + 1))
          BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":true,\"method\":\"configs-image\"},"
        else
          svc_s=$(( $(date +%s) - svc_start ))
          log_err "  [$svc] FAILED (${svc_s}s)"
          FAILED=$((FAILED + 1))
          BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":false,\"method\":\"configs-image\"},"
        fi
      else
        log "  [$svc] configs extracted but no docker-run.sh — skipping"
      fi
    else
      log "  [$svc] no containers, no docker-run.sh, no configs image — skipping"
    fi
  fi

  sleep "$START_DELAY"
done

STARTUP_ELAPSED=$(( $(date +%s) - BOOT_START ))
log "Startup: $STARTED ok, $FAILED failed (${STARTUP_ELAPSED}s)"

# ══════════════════════════════════════════════════════════════════════════
# PHASE 5: Health verification + container logs on failure
# ══════════════════════════════════════════════════════════════════════════
log "═══ PHASE 5: Health verification ═══"
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
    while [ "$health" = "starting" ] && [ "$waited" -lt 120 ]; do
      health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
      [ "$health" = "starting" ] && sleep 5 && waited=$((waited + 5))
    done

    if [ "$health" = "healthy" ]; then
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
      log "  $name: healthy"
    else
      log_err "  $name: UNHEALTHY ($health) — logs + restart"
      # Dump last 20 lines of logs to journal
      docker logs --tail 20 "$container" 2>&1 | while IFS= read -r line; do
        echo "[container-init] [$name] $line" | systemd-cat -t container-init -p warning 2>/dev/null || true
      done
      docker restart "$container" >/dev/null 2>&1
      sleep 10
      health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
      RESTARTED=$((RESTARTED + 1))
      if [ "$health" = "healthy" ]; then
        log "  $name: healthy after restart"
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
      else
        log_err "  $name: STILL UNHEALTHY ($health)"
        UNHEALTHY="$UNHEALTHY $name"
      fi
    fi
  else
    state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
    if [ "$state" = "running" ]; then
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
      log_err "  $name: NOT RUNNING ($state) — logs:"
      docker logs --tail 20 "$container" 2>&1 | while IFS= read -r line; do
        echo "[container-init] [$name] $line" | systemd-cat -t container-init -p warning 2>/dev/null || true
      done
      UNHEALTHY="$UNHEALTHY $name"
    fi
  fi
done < <(docker ps -q 2>/dev/null)

HEALTH_S=$(( $(date +%s) - HEALTH_START ))
TOTAL_ELAPSED=$(( $(date +%s) - BOOT_START ))
log "Health: $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy, $RESTARTED restarted (${HEALTH_S}s)"

# ══════════════════════════════════════════════════════════════════════════
# PHASE 6: Report + ntfy
# ══════════════════════════════════════════════════════════════════════════
log "═══ PHASE 6: Report ═══"

cat > "$BOOT_JSON" 2>/dev/null <<EOF || true
{"boot":"$(date -Iseconds)","vm":"$VM_ALIAS","hostname":"$HOSTNAME","docker_s":$DOCKER_ELAPSED,"projects":$PROJECT_COUNT,"started":$STARTED,"failed":$FAILED,"containers":$TOTAL_CONTAINERS,"healthy":$HEALTHY_COUNT,"restarted":$RESTARTED,"total_s":$TOTAL_ELAPSED,"detail":[${BOOT_RESULTS%,}]}
EOF

if [ -n "$UNHEALTHY" ]; then
  ntfy "Boot: UNHEALTHY:$UNHEALTHY" "vm=$VM_ALIAS | Docker:${DOCKER_ELAPSED}s | $STARTED/$PROJECT_COUNT projects | $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | ${TOTAL_ELAPSED}s" "high" "warning"
elif [ "$FAILED" -gt 0 ]; then
  ntfy "Boot: $FAILED failed" "vm=$VM_ALIAS | Docker:${DOCKER_ELAPSED}s | $STARTED/$PROJECT_COUNT projects | $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | ${TOTAL_ELAPSED}s" "high" "warning"
else
  ntfy "Boot OK: $PROJECT_COUNT projects" "vm=$VM_ALIAS | Docker:${DOCKER_ELAPSED}s | $HEALTHY_COUNT/$TOTAL_CONTAINERS healthy | ${TOTAL_ELAPSED}s" "default" "white_check_mark"
fi

log "═══ CONTAINER INIT COMPLETE (${TOTAL_ELAPSED}s) ═══"
