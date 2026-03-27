#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder-ship.sh — Ship services to a VM                   ║
# ║                                                                  ║
# ║ Called by cloud-builder.sh, or standalone (Dagu, CLI).           ║
# ║ Usage: cloud-builder-ship.sh <vm-alias> [service-filter]         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -u  # no -e/-o pipefail: parallel jobs must not kill the script on failure

VM="${1:?Usage: ship-vm.sh <vm-alias> [service-filter]}"
FILTER="${2:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# ── Trace collection ─────────────────────────────────────────────
RUN_START=$(date +%s)
TRACE_SERVICES="[]"

GHA_CONFIG="cloud-data/cloud-data-gha-config.json"
if [ ! -f "$GHA_CONFIG" ]; then
  echo "ERROR: $GHA_CONFIG not found" >&2
  exit 1
fi

# Get services for this VM
SERVICES=$(jq -r --arg vm "$VM" '
  .services | to_entries[]
  | select(.value.vm == $vm)
  | [.value.dir, .key, (.value.has_docker // false | tostring)]
  | join("|")
' "$GHA_CONFIG")

if [ -z "$SERVICES" ]; then
  echo "No services found for VM: $VM"
  exit 0
fi

# Detect changed dirs (GHA provides HEAD~1, CLI/Dagu ships all)
CHANGED_DIRS=""
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" ]; then
  CHANGED_DIRS=$(git diff --name-only HEAD~1 HEAD -- 'a_solutions/*/src/' 2>/dev/null | awk -F/ '{print $2}' | sort -u | tr '\n' ' ')
fi

TOTAL=$(echo "$SERVICES" | wc -l)
_CORES=$(nproc 2>/dev/null || echo 2)
MAX_PARALLEL="${SHIP_PARALLEL:-$(( _CORES > 1 ? _CORES - 1 : 1 ))}"  # nproc-1, min 1

echo "═══════════════════════════════════════════════"
echo "Ship → $VM ($TOTAL services, max $MAX_PARALLEL parallel)"
echo "═══════════════════════════════════════════════"

# ── Per-service worker (runs in background) ──────────────────────
RESULTS_DIR=$(mktemp -d)

ship_one() {
  local dir="$1" name="$2" has_docker="$3"
  local log_file="$RESULTS_DIR/${name}.log"
  local svc_start
  svc_start=$(date +%s)

  {
    echo "── Ship: $name ($dir) ──"

    BUILD_SH="a_solutions/${dir}/build.sh"
    if [ ! -f "$BUILD_SH" ]; then
      echo "SKIP $name (no build.sh)"
      echo "skip" > "$RESULTS_DIR/${name}.status"
      echo "0" > "$RESULTS_DIR/${name}.dur"
      return 0
    fi

    if [ "$has_docker" = "true" ]; then
      export REMOTE_BUILD="true"
    else
      unset REMOTE_BUILD 2>/dev/null || true
    fi

    if bash "$BUILD_SH" ship; then
      echo "OK $name"
      echo "ok" > "$RESULTS_DIR/${name}.status"
    else
      echo "FAIL $name (exit $?)"
      echo "fail" > "$RESULTS_DIR/${name}.status"
    fi
  } 2>&1 | stdbuf -oL sed "s/^/[$name] /" | tee "$log_file"

  echo "$(( $(date +%s) - svc_start ))" > "$RESULTS_DIR/${name}.dur"
}

# ── Launch services in parallel (xargs-based) ────────────────────
SHIP_CMDS=$(mktemp)

while IFS='|' read -r dir name has_docker; do
  if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  if [ -n "$CHANGED_DIRS" ] && ! echo "$CHANGED_DIRS" | grep -q "$dir"; then
    echo "SKIP $name (unchanged)"
    echo "skip" > "$RESULTS_DIR/${name}.status"
    echo "0" > "$RESULTS_DIR/${name}.dur"
    continue
  fi

  echo "$dir|$name|$has_docker" >> "$SHIP_CMDS"
done <<< "$SERVICES"

export -f ship_one
export RESULTS_DIR

cat "$SHIP_CMDS" | xargs -P "$MAX_PARALLEL" -I{} bash -c '
  IFS="|" read -r dir name has_docker <<< "{}"
  ship_one "$dir" "$name" "$has_docker"
'
rm -f "$SHIP_CMDS"

# ── Collect results ──────────────────────────────────────────────
OK=0; FAIL=0; SKIP=0

while IFS='|' read -r dir name has_docker; do
  [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
  status=$(cat "$RESULTS_DIR/${name}.status" 2>/dev/null || echo "fail")
  dur=$(cat "$RESULTS_DIR/${name}.dur" 2>/dev/null || echo "0")
  case "$status" in
    ok)   OK=$((OK + 1)) ;;
    skip) SKIP=$((SKIP + 1)) ;;
    *)    FAIL=$((FAIL + 1)) ;;
  esac
  TRACE_SERVICES=$(jq --arg n "$name" --arg d "$dir" --arg s "$status" --argjson dur "$dur" \
    '. + [{"name":$n,"dir":$d,"status":$s,"duration_s":$dur}]' <<< "$TRACE_SERVICES")
done <<< "$SERVICES"

rm -rf "$RESULTS_DIR"

echo ""
echo "═══════════════════════════════════════════════"
echo "Ship → $VM: $OK ok, $FAIL failed, $SKIP skipped (of $TOTAL)"

# ── Write trace JSON ─────────────────────────────────────────────
# TRACE_DIR env var: set by GHA template (-v mount), fallback for CLI/Dagu
RUN_DUR=$(( $(date +%s) - RUN_START ))
RUN_STATUS="success"; [ "$FAIL" -gt 0 ] && RUN_STATUS="failure"

TRACE_DIR="${TRACE_DIR:-$REPO_ROOT/cloud-data/traces-gha}"
mkdir -p "$TRACE_DIR"

jq -n \
  --arg vm "$VM" \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  --arg run_url "https://github.com/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}" \
  --arg sha "${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}" \
  --arg trigger "${GITHUB_EVENT_NAME:-manual}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson dur "$RUN_DUR" \
  --argjson total "$TOTAL" \
  --argjson ok "$OK" \
  --argjson fail "$FAIL" \
  --argjson skip "$SKIP" \
  --arg status "$RUN_STATUS" \
  --argjson services "$TRACE_SERVICES" \
  '{vm:$vm,run_id:$run_id,run_url:$run_url,sha:$sha,trigger:$trigger,ts:$ts,duration_s:$dur,total:$total,ok:$ok,fail:$fail,skip:$skip,status:$status,services:$services}' \
  > "$TRACE_DIR/${VM}.json"

echo "Trace written: $TRACE_DIR/${VM}.json"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
