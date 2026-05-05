#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : b_infra/home-manager/nixhm-sudo-oci-apps/src/pilot/packages/vm-images-pull-up.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# VM Images Pull & Up — serial Docker image pull + compose up
# POSIX sh — no bash required
#
# Usage:
#   vm-images-pull-up.sh                           # discover from /opt/containers/
#   vm-images-pull-up.sh --manifest file.json      # read services from JSON manifest
#   vm-images-pull-up.sh --manifest file.json svc  # filter to one service
#
# Phase 1: Serial docker pull for each service (avoids memory spike)
# Phase 2: Serial docker compose up for each service
#
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/home-manager/_shared/modules/vm-images-pull-up.sh

set -u
HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
LOG="/var/log/images-pull-up.log"
CONTAINERS_DIR="/opt/containers"
MANIFEST=""
FILTER=""

# ── Parse args ──────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    *)          FILTER="$1"; shift ;;
  esac
done

log() {
  MSG="$(date -Is) [$HOSTNAME] [images-pull-up] $1"
  printf '%s\n' "$MSG" >> "$LOG" 2>/dev/null && sync "$LOG" 2>/dev/null
  printf '%s\n' "$MSG"
}

die() { log "FATAL: $1"; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  log "Docker not running — starting"
  sudo systemctl start docker 2>/dev/null || true
  sleep 3
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || die "Docker failed to start"
fi

# GHCR login
if [ -f "$HOME/.docker/config.json" ]; then
  log "GHCR: using existing credentials"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin 2>/dev/null
  log "GHCR: logged in"
fi

# ── Discover services ───────────────────────────────────────────
# Two modes: manifest JSON or filesystem discovery

if [ -n "$MANIFEST" ]; then
  # ── Manifest mode: read from JSON ──
  [ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"
  command -v jq >/dev/null 2>&1 || die "jq required for manifest mode"

  TOTAL=$(jq '.services | length' "$MANIFEST")
  log "START: manifest=$MANIFEST ($TOTAL services, filter=${FILTER:-all})"

  # ── Phase 1: Serial pull ──────────────────────────────────────
  log "═══ PHASE 1: Pulling images ═══"
  PULL_OK=0; PULL_FAIL=0; IDX=0

  for i in $(seq 0 $((TOTAL - 1))); do
    NAME=$(jq -r ".services[$i].name" "$MANIFEST")
    COMPOSE_PATH=$(jq -r ".services[$i].compose_path" "$MANIFEST")
    HAS_BUILD=$(jq -r ".services[$i].has_docker_build" "$MANIFEST")
    IMAGES=$(jq -r ".services[$i].images[]" "$MANIFEST" 2>/dev/null)

    [ -n "$FILTER" ] && [ "$NAME" != "$FILTER" ] && continue
    IDX=$((IDX + 1))

    # Pull explicit images (skip build-only services)
    if [ -n "$IMAGES" ] && [ "$HAS_BUILD" != "true" ]; then
      for img in $IMAGES; do
        log "[$IDX] PULL: $img ($NAME)"
        if docker pull "$img" 2>&1; then
          PULL_OK=$((PULL_OK + 1))
        else
          log "[$IDX] PULL FAIL: $img"
          PULL_FAIL=$((PULL_FAIL + 1))
        fi
      done
    elif [ -d "$COMPOSE_PATH" ] && [ -f "$COMPOSE_PATH/docker-compose.yml" ]; then
      # Fallback: extract images from compose and pull individually
      # (docker compose pull spawns heavy Go binary — kills E2 micros)
      ENV_FLAG=""
      [ -f "$COMPOSE_PATH/.secrets" ] && ENV_FLAG="--env-file $COMPOSE_PATH/.secrets"
      log "[$IDX] PULL IMAGES: $NAME"
      if (cd "$COMPOSE_PATH" && docker compose $ENV_FLAG config --images 2>/dev/null | sort -u | while read img; do docker pull "$img" 2>/dev/null || true; done); then
        PULL_OK=$((PULL_OK + 1))
      else
        PULL_FAIL=$((PULL_FAIL + 1))
      fi
    fi

    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    log "[$IDX] mem_free=${MEM_AVAIL}MB after $NAME"
  done

  log "PHASE 1 DONE: $PULL_OK pulled, $PULL_FAIL failed"

  # ── Phase 2: Serial compose up ────────────────────────────────
  log "═══ PHASE 2: Starting containers ═══"
  UP_OK=0; UP_FAIL=0; IDX=0

  for i in $(seq 0 $((TOTAL - 1))); do
    NAME=$(jq -r ".services[$i].name" "$MANIFEST")
    COMPOSE_PATH=$(jq -r ".services[$i].compose_path" "$MANIFEST")
    HAS_BUILD=$(jq -r ".services[$i].has_docker_build" "$MANIFEST")

    [ -n "$FILTER" ] && [ "$NAME" != "$FILTER" ] && continue
    [ -d "$COMPOSE_PATH" ] || { log "SKIP: $NAME ($COMPOSE_PATH not found)"; continue; }
    [ -f "$COMPOSE_PATH/docker-compose.yml" ] || { log "SKIP: $NAME (no docker-compose.yml)"; continue; }
    IDX=$((IDX + 1))

    ENV_FLAG=""
    [ -f "$COMPOSE_PATH/.secrets" ] && ENV_FLAG="--env-file $COMPOSE_PATH/.secrets"

    log "[$IDX] UP: $NAME"
    if (cd "$COMPOSE_PATH" && docker compose $ENV_FLAG pull --quiet 2>/dev/null; docker compose $ENV_FLAG up -d --no-build --force-recreate 2>&1); then
      log "[$IDX] UP OK: $NAME"
      UP_OK=$((UP_OK + 1))
    else
      log "[$IDX] UP FAIL: $NAME (exit $?)"
      UP_FAIL=$((UP_FAIL + 1))
    fi

    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    CTRS=$(docker ps -q 2>/dev/null | wc -l)
    log "[$IDX] mem_free=${MEM_AVAIL}MB containers=$CTRS after $NAME"
  done

else
  # ── Filesystem discovery mode (backward compatible) ──
  [ -d "$CONTAINERS_DIR" ] || die "$CONTAINERS_DIR not found"

  SERVICES=""
  TOTAL=0
  for dir in "$CONTAINERS_DIR"/*/; do
    [ -d "$dir" ] || continue
    [ -f "$dir/docker-compose.yml" ] || continue
    name=$(basename "$dir")
    [ -n "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
    SERVICES="$SERVICES $name"
    TOTAL=$((TOTAL + 1))
  done

  [ "$TOTAL" -eq 0 ] && { log "No services found"; exit 0; }
  log "START: filesystem discovery ($TOTAL services, filter=${FILTER:-all})"

  # Phase 1: Serial pull
  log "═══ PHASE 1: Pulling images ═══"
  PULL_OK=0; PULL_FAIL=0; IDX=0
  for name in $SERVICES; do
    IDX=$((IDX + 1))
    dir="$CONTAINERS_DIR/$name"
    ENV_FLAG=""
    [ -f "$dir/.secrets" ] && ENV_FLAG="--env-file $dir/.secrets"
    log "[$IDX/$TOTAL] PULL: $name"
    if (cd "$dir" && docker compose $ENV_FLAG config --images 2>/dev/null | sort -u | while read img; do docker pull "$img" 2>/dev/null || true; done); then
      PULL_OK=$((PULL_OK + 1))
    else
      PULL_FAIL=$((PULL_FAIL + 1))
    fi
    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    log "[$IDX/$TOTAL] mem_free=${MEM_AVAIL}MB after $name"
  done
  log "PHASE 1 DONE: $PULL_OK pulled, $PULL_FAIL failed"

  # Phase 2: Serial compose up
  log "═══ PHASE 2: Starting containers ═══"
  UP_OK=0; UP_FAIL=0; IDX=0
  for name in $SERVICES; do
    IDX=$((IDX + 1))
    dir="$CONTAINERS_DIR/$name"
    ENV_FLAG=""
    [ -f "$dir/.secrets" ] && ENV_FLAG="--env-file $dir/.secrets"
    log "[$IDX/$TOTAL] UP: $name"
    if (cd "$dir" && docker compose $ENV_FLAG pull --quiet 2>/dev/null; docker compose $ENV_FLAG up -d --no-build --force-recreate 2>&1); then
      UP_OK=$((UP_OK + 1))
    else
      UP_FAIL=$((UP_FAIL + 1))
    fi
    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    CTRS=$(docker ps -q 2>/dev/null | wc -l)
    log "[$IDX/$TOTAL] mem_free=${MEM_AVAIL}MB containers=$CTRS after $name"
  done
fi

# ── Summary ─────────────────────────────────────────────────────
TOTAL_CTRS=$(docker ps -q 2>/dev/null | wc -l)
HEALTHY=$(docker ps --filter health=healthy -q 2>/dev/null | wc -l)
MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")

log "═══ DONE ═══"
log "Pull: ${PULL_OK:-0} ok, ${PULL_FAIL:-0} fail | Up: ${UP_OK:-0} ok, ${UP_FAIL:-0} fail"
log "Containers: $TOTAL_CTRS running ($HEALTHY healthy) | mem_free=${MEM_AVAIL}MB"

[ "${PULL_FAIL:-0}" -gt 0 ] || [ "${UP_FAIL:-0}" -gt 0 ] && exit 1
exit 0
