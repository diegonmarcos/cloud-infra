#!/usr/bin/env bash
# ── Build + push all Docker images to GHCR ──
# Portable: works in GHA, Dagu, CLI
# Usage: ship-ghcr.sh [service-filter]
set -euo pipefail

FILTER="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# 2026-04-27 migrated: cloud-data-gha-config.json -> build-gha.json
# (per-service build-{name}.json convention; derived from
# _cloud-data-consolidated.json by 2_configs/src/engines/cloud-data-config-derive.ts).
# Legacy paths kept as fallbacks during rollout.
GHA_CONFIG=""
for _p in \
    "/app/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/build-gha.json"; do
    [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
done
if [ -z "$GHA_CONFIG" ]; then
    # Fallback: extract _gha slice from consolidated.
    _CONS_FOR_GHA=""
    for _p in \
        "/app/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/_cloud-data-consolidated.json" \
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
            "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/cloud-data-gha-config.json" \
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

# Get all Docker-enabled services
SERVICES=$(jq -r '
  .services | to_entries[]
  | select(.value.has_docker == true)
  | [.value.dir, .key, (.value.docker_image // "")]
  | join("|")
' "$GHA_CONFIG")

if [ -z "$SERVICES" ]; then
  echo "No Docker services found"
  exit 0
fi

OK=0
FAIL=0

echo "═══════════════════════════════════════════════"
echo "Ship → GHCR images"
echo "═══════════════════════════════════════════════"

echo "$SERVICES" | while IFS='|' read -r dir name image; do
  if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  BUILD_SH="a_solutions/${dir}/build.sh"
  if [ ! -f "$BUILD_SH" ]; then
    echo "SKIP $name (no build.sh)"
    continue
  fi

  echo ""
  echo "── Build: $name ($dir) ──"

  if bash "$BUILD_SH" docker; then
    echo "OK $name"
    OK=$((OK + 1))

    # Make package public
    pkg_name=$(echo "$image" | awk -F/ '{print $NF}')
    if [ -n "$pkg_name" ] && command -v gh >/dev/null 2>&1; then
      gh api --method PUT "/user/packages/container/${pkg_name}/visibility" -f visibility=public 2>/dev/null || true
    fi
  else
    echo "FAIL $name (exit $?)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "═══════════════════════════════════════════════"
echo "GHCR: $OK ok, $FAIL failed"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
