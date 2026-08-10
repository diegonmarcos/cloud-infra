#!/usr/bin/env bash
# ── Ship all services for a VM ──
# Portable: works in GHA, Dagu, CLI
# Usage: ship-vm.sh <vm-alias> [service-filter]
#   vm-alias: gcp-proxy, oci-apps, oci-mail, oci-analytics, gcp-t4
#   service-filter: optional, only ship this service dir (e.g. bc-obs_dagu)
set -uo pipefail  # no -e: build failures are caught by if/else in the loop

VM="${1:?Usage: ship-vm.sh <vm-alias> [service-filter]}"
FILTER="${2:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# ── Trace collection ─────────────────────────────────────────────
RUN_START=$(date +%s)
TRACE_SERVICES="[]"

# 2026-04-27 migrated: cloud-data-gha-config.json -> build-gha.json
GHA_CONFIG=""
for _p in \
    "/app/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/1_cloud-configs/dist/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/build-gha.json"; do
    [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
done
if [ -z "$GHA_CONFIG" ]; then
    # Fallback: extract _gha slice from consolidated.
    _CONS_FOR_GHA=""
    for _p in \
        "/app/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/1_cloud-configs/dist/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/_cloud-data-consolidated.json"; do
        [ -f "$_p" ] && { _CONS_FOR_GHA="$_p"; break; }
    done
    if [ -n "$_CONS_FOR_GHA" ]; then
        GHA_CONFIG="${RUNNER_TEMP:-/tmp}/gha-config.json"
        jq '
          ._gha as $g
          | (.vms | to_entries | map({key: .value.ssh_alias, value: .value.wg_ip}) | from_entries) as $alias_to_wg
          | $g
          | .vms |= with_entries(.value += {wg_ip: ($alias_to_wg[.key] // null)})
        ' "$_CONS_FOR_GHA" > "$GHA_CONFIG"
    else
        for _p in \
            "/app/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/z_archive/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data-gha-config.json"; do
            [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
        done
    fi
fi
if [ -z "$GHA_CONFIG" ]; then
  echo "FATAL: build-gha.json (or legacy fallbacks) not found" >&2
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
  # `a_solutions/*/src/` (trailing slash) is a directory pathspec that, combined with
  # the `*`, MISSES files directly under src/ (e.g. src/compose.nix) — proven: it
  # skipped a real cloud-cgc-mcp change. `**` recurses at any depth (matches the
  # detect step in ship.yml). Without this, changed services are wrongly "unchanged".
  CHANGED_DIRS=$(git diff --name-only HEAD~1 HEAD -- 'a_solutions/*/src/**' 2>/dev/null | awk -F/ '{print $2}' | sort -u | tr '\n' ' ')
fi

OK=0
FAIL=0
SKIP=0
TOTAL=$(echo "$SERVICES" | wc -l)

echo "═══════════════════════════════════════════════"
echo "Ship → $VM ($TOTAL services)"
echo "═══════════════════════════════════════════════"

while IFS='|' read -r dir name has_docker; do
  # Apply filter
  if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  # Skip unchanged (only in GHA push events). Exact token match against the
  # space-delimited CHANGED_DIRS — a substring grep could mis-match a similarly
  # named folder (false deploy) or partial (false skip).
  if [ -n "$CHANGED_DIRS" ]; then
    _changed=0
    case " $CHANGED_DIRS " in *" $dir "*) _changed=1 ;; esac
    if [ "$_changed" -eq 0 ]; then
      echo "SKIP $name (unchanged)"
      SKIP=$((SKIP + 1))
      TRACE_SERVICES=$(jq --arg n "$name" --arg d "$dir" \
        '. + [{"name":$n,"dir":$d,"status":"skip","duration_s":0}]' <<< "$TRACE_SERVICES")
      continue
    fi
  fi

  BUILD_SH="a_solutions/${dir}/build.sh"
  if [ ! -f "$BUILD_SH" ]; then
    echo "SKIP $name (no build.sh)"
    SKIP=$((SKIP + 1))
    TRACE_SERVICES=$(jq --arg n "$name" --arg d "$dir" \
      '. + [{"name":$n,"dir":$d,"status":"skip","duration_s":0}]' <<< "$TRACE_SERVICES")
    continue
  fi

  echo ""
  echo "── Ship: $name ($dir) ──"

  # Set REMOTE_BUILD for Docker services
  if [ "$has_docker" = "true" ]; then
    export REMOTE_BUILD="true"
  else
    unset REMOTE_BUILD 2>/dev/null || true
  fi

  svc_start=$(date +%s)
  if bash "$BUILD_SH" ship; then
    echo "OK $name"
    OK=$((OK + 1))
    svc_status="ok"
  else
    echo "FAIL $name (exit $?)"
    FAIL=$((FAIL + 1))
    svc_status="fail"
  fi
  svc_dur=$(( $(date +%s) - svc_start ))
  TRACE_SERVICES=$(jq --arg n "$name" --arg d "$dir" --arg s "$svc_status" --argjson dur "$svc_dur" \
    '. + [{"name":$n,"dir":$d,"status":$s,"duration_s":$dur}]' <<< "$TRACE_SERVICES")
done <<< "$SERVICES"

echo ""
echo "═══════════════════════════════════════════════"
echo "Ship → $VM: $OK ok, $FAIL failed, $SKIP skipped (of $TOTAL)"

# ── Write trace JSON ─────────────────────────────────────────────
# TRACE_DIR env var: set by GHA template (-v mount), fallback for CLI/Dagu
RUN_DUR=$(( $(date +%s) - RUN_START ))
RUN_STATUS="success"; [ "$FAIL" -gt 0 ] && RUN_STATUS="failure"

TRACE_DIR="${TRACE_DIR:-$REPO_ROOT/1_configs/dist/reports/traces-gha}"
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
