#!/bin/bash
# Container Init — VM-side mirror of build.sh ship
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/home-manager/_shared/modules/container-control-init.sh
#
# Phases:
#   0:   Start Docker daemon
#   0.5: HM self-update (pull HM image, activate if changed)
#   1:   Git pull cloud-data
#   2:   For each service: pull configs + pull image (parallel), start/recreate
#   3:   Health check + report
set -uo pipefail

# ── Sudo: escalate if not root ──
if [ "$(id -u)" != "0" ]; then exec sudo "$0" "$@"; fi

# ── PATH: ensure nix + docker binaries available ──
for p in /home/*/nix-profile/bin /home/*/.nix-profile/bin /nix/var/nix/profiles/default/bin; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

# ── Config ──
CONFIG="/opt/scripts/container-init.json"
[ -f "$CONFIG" ] || { echo "[container-init] FATAL: $CONFIG not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[container-init] FATAL: jq not found" >&2; exit 1; }

VM_ALIAS=$(jq -r '.vm_alias' "$CONFIG")
CLOUD_DATA_REPO=$(jq -r '.cloud_data_repo // "https://github.com/diegonmarcos/cloud-data.git"' "$CONFIG")
CLOUD_DATA_DIR=$(jq -r '.cloud_data_dir // "/home/diego/git/cloud-data"' "$CONFIG")
CONTAINERS_DIR=$(jq -r '.containers_dir // "/opt/containers"' "$CONFIG")
NTFY_BASE=$(jq -r '.ntfy_base // "https://rss.diegonmarcos.com"' "$CONFIG")
NTFY_TOPIC=$(jq -r '.ntfy_topic // "container-init"' "$CONFIG")
DOCKER_TIMEOUT=$(jq -r '.docker_timeout // 60' "$CONFIG")
START_DELAY=$(jq -r '.start_delay // 3' "$CONFIG")
GIT_USER=$(jq -r '.git_user // "diego"' "$CONFIG")
HM_DELIVERY=$(jq -r '.hm_delivery // "nix-copy"' "$CONFIG")
HM_IMAGE=$(jq -r '.hm_image // ""' "$CONFIG")
HM_USER=$(jq -r '.hm_user // "diego"' "$CONFIG")
REGISTRY="ghcr.io/diegonmarcos"

HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
BOOT_START=$(date +%s)
BOOT_JSON="/var/log/container-init-boot.json"
LOG_FILE="/var/log/container-init.log"

# ── Logging ──
log()     { local msg="[container-init] +$(( $(date +%s) - BOOT_START ))s $*"; echo "$msg" >&2; echo "$msg" >> "$LOG_FILE" 2>/dev/null; }
log_err() { local msg="[container-init] ERROR: $*"; echo "$msg" >&2; echo "$msg" >> "$LOG_FILE" 2>/dev/null; }
mem_free() { free -m 2>/dev/null | awk '/Mem:/{print $4}'; }
ntfy() {
  curl -sf -X POST "${NTFY_BASE}/${NTFY_TOPIC}" \
    -H "Title: [$HOSTNAME] $1" -H "Priority: ${3:-default}" -H "Tags: ${4:-whale}" \
    -d "$2" >/dev/null 2>&1 || true
}

# ══════════════════════════════════════════════════════════════
# PHASE 0: Docker daemon
# ══════════════════════════════════════════════════════════════
log "═══ PHASE 0: Docker daemon ═══"
log "vm=$VM_ALIAS hostname=$HOSTNAME mem=$(mem_free)MB free"

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  log "Starting Docker..."
  systemctl start docker 2>/dev/null
  for i in $(seq 1 "$DOCKER_TIMEOUT"); do
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && break
    [ $((i % 10)) -eq 0 ] && log "  waiting... (${i}s)"
    sleep 1
  done
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { log_err "FATAL: Docker failed"; exit 1; }
fi
DOCKER_S=$(( $(date +%s) - BOOT_START ))
log "Docker ready (${DOCKER_S}s)"

# ══════════════════════════════════════════════════════════════
# PHASE 0.5: HM self-update
# ══════════════════════════════════════════════════���═══════════
if [ "$HM_DELIVERY" = "docker" ] && [ -n "$HM_IMAGE" ]; then
  log "═══ PHASE 0.5: HM self-update ═══"
  OLD_ID=$(docker inspect --format '{{.Id}}' "$HM_IMAGE" 2>/dev/null || echo "none")
  if docker pull "$HM_IMAGE" >/dev/null 2>&1; then
    NEW_ID=$(docker inspect --format '{{.Id}}' "$HM_IMAGE" 2>/dev/null || echo "none")
    if [ "$OLD_ID" != "$NEW_ID" ]; then
      log "  HM image updated — activating"
      HM_HOME=$(eval echo "~$HM_USER")
      docker run --rm -v /nix:/nix -v "$HM_HOME:$HM_HOME" -v /etc:/etc -v /tmp:/tmp "$HM_IMAGE" 2>&1 | while IFS= read -r l; do log "    $l"; done
      log "  HM activated"
    else
      log "  HM unchanged"
    fi
  else
    log "  HM pull failed — using existing"
  fi
fi

# ══════════════════════════════════════════════════════════════
# PHASE 1: Cloud-data sync
# ══════════════════════════════════════════════════════════════
log "═══ PHASE 1: Cloud-data sync ═══"
mkdir -p "$(dirname "$CLOUD_DATA_DIR")" 2>/dev/null || true
if [ -d "$CLOUD_DATA_DIR/.git" ]; then
  (cd "$CLOUD_DATA_DIR" && git fetch origin main 2>&1 && git reset --hard origin/main 2>&1) >/dev/null 2>&1 && log "cloud-data updated" || log "cloud-data pull failed — using cached"
else
  git clone --depth 1 "$CLOUD_DATA_REPO" "$CLOUD_DATA_DIR" >/dev/null 2>&1 && log "cloud-data cloned" || log_err "cloud-data clone failed"
fi

# Find VM manifest. The modern source is build-vm-{alias}.json (dist/ root);
# the deprecated cloud-data-containers-{alias}.json is kept as a back-compat
# fallback only — it has been removed from the derive pipeline.
CONTAINERS_JSON=""
for pattern in "build-vm-${VM_ALIAS}.json" "cloud-data-containers-${VM_ALIAS}.json"; do
  MATCH=$(find "$CLOUD_DATA_DIR" -maxdepth 2 -name "$pattern" 2>/dev/null | head -1)
  [ -n "$MATCH" ] && CONTAINERS_JSON="$MATCH" && break
done
[ -z "$CONTAINERS_JSON" ] && { log_err "No manifest for vm=$VM_ALIAS (looked for build-vm-${VM_ALIAS}.json)"; exit 1; }

DECLARED_SERVICES=$(jq -r '.services[].compose_path' "$CONTAINERS_JSON")
PROJECT_COUNT=$(echo "$DECLARED_SERVICES" | wc -w)
log "Declared: $PROJECT_COUNT services"

# ══════════════════════════════════════════════════════════════
# PHASE 2: For each service — pull configs + image, start/recreate
# ══════════════════════════════════════════════════════════════
log "═══ PHASE 2: Pull + Start ($PROJECT_COUNT services) ═══"
STARTED=0
FAILED=0
BOOT_RESULTS=""

for dir in $DECLARED_SERVICES; do
  svc=$(basename "$dir")
  svc_start=$(date +%s)
  log "  [$svc] mem=$(mem_free)MB"

  # ── Pull configs image, extract if changed ──
  CONFIGS_IMG="${REGISTRY}/${svc}-configs:latest"
  OLD_CFG_ID=$(docker inspect --format '{{.Id}}' "$CONFIGS_IMG" 2>/dev/null || echo "none")
  if docker pull "$CONFIGS_IMG" >/dev/null 2>&1; then
    NEW_CFG_ID=$(docker inspect --format '{{.Id}}' "$CONFIGS_IMG" 2>/dev/null || echo "none")
    if [ "$OLD_CFG_ID" != "$NEW_CFG_ID" ]; then
      log "  [$svc] configs updated — extracting"
      mkdir -p "$dir" 2>/dev/null || true
      docker run --rm -v "$dir:/out" "$CONFIGS_IMG" 2>/dev/null
    fi
  fi

  # ── Run the service's compose script (it owns pull + run) ──
  COMPOSE_SCRIPT=""
  [ -f "$dir/build-step-compose-custom.sh" ] && COMPOSE_SCRIPT="build-step-compose-custom.sh"
  [ -z "$COMPOSE_SCRIPT" ] && [ -f "$dir/docker-run.sh" ] && COMPOSE_SCRIPT="docker-run.sh"

  if [ -n "$COMPOSE_SCRIPT" ]; then
    if (cd "$dir" && sh "$COMPOSE_SCRIPT") >/dev/null 2>&1; then
      svc_s=$(( $(date +%s) - svc_start ))
      log "  [$svc] ok (${svc_s}s)"
      STARTED=$((STARTED + 1))
      BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":true},"
    else
      svc_s=$(( $(date +%s) - svc_start ))
      log_err "  [$svc] FAILED (${svc_s}s)"
      FAILED=$((FAILED + 1))
      BOOT_RESULTS="${BOOT_RESULTS}{\"name\":\"$svc\",\"s\":$svc_s,\"ok\":false},"
    fi
  else
    log "  [$svc] no compose script — skipping (needs build.sh ship)"
  fi

  sleep "$START_DELAY"
done

STARTUP_S=$(( $(date +%s) - BOOT_START ))
log "Phase 2: $STARTED ok, $FAILED failed (${STARTUP_S}s)"

# ══════════════════════════════════════════════════════════════
# PHASE 3: Health check + report
# ══════════════════════════════════════════════════════════════
log "═══ PHASE 3: Health check ═══"
sleep 10
HEALTHY=0
TOTAL=0
UNHEALTHY=""

for cid in $(docker ps -q 2>/dev/null); do
  TOTAL=$((TOTAL + 1))
  name=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's/^\///')
  has_hc=$(docker inspect --format='{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$cid" 2>/dev/null || echo "no")

  if [ "$has_hc" = "yes" ]; then
    health="starting"; waited=0
    while [ "$health" = "starting" ] && [ "$waited" -lt 120 ]; do
      health=$(docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")
      [ "$health" = "starting" ] && sleep 5 && waited=$((waited + 5))
    done
    if [ "$health" = "healthy" ]; then
      HEALTHY=$((HEALTHY + 1))
    else
      log_err "  $name: UNHEALTHY ($health)"
      docker restart "$cid" >/dev/null 2>&1
      UNHEALTHY="$UNHEALTHY $name"
    fi
  else
    state=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
    [ "$state" = "running" ] && HEALTHY=$((HEALTHY + 1)) || UNHEALTHY="$UNHEALTHY $name"
  fi
done

TOTAL_S=$(( $(date +%s) - BOOT_START ))
log "Health: $HEALTHY/$TOTAL healthy (${TOTAL_S}s)"

# ── Report ──
cat > "$BOOT_JSON" 2>/dev/null <<EOF || true
{"boot":"$(date -Iseconds)","vm":"$VM_ALIAS","hostname":"$HOSTNAME","docker_s":$DOCKER_S,"projects":$PROJECT_COUNT,"started":$STARTED,"failed":$FAILED,"containers":$TOTAL,"healthy":$HEALTHY,"total_s":$TOTAL_S,"detail":[${BOOT_RESULTS%,}]}
EOF

if [ -n "$UNHEALTHY" ]; then
  ntfy "UNHEALTHY:$UNHEALTHY" "$STARTED/$PROJECT_COUNT | $HEALTHY/$TOTAL healthy | ${TOTAL_S}s" "high" "warning"
elif [ "$FAILED" -gt 0 ]; then
  ntfy "$FAILED failed" "$STARTED/$PROJECT_COUNT | $HEALTHY/$TOTAL healthy | ${TOTAL_S}s" "high" "warning"
else
  ntfy "OK: $PROJECT_COUNT svcs" "$HEALTHY/$TOTAL healthy | ${TOTAL_S}s" "default" "white_check_mark"
fi

log "═══ COMPLETE (${TOTAL_S}s) ═══"
