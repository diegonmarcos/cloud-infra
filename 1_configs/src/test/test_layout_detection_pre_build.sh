#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 15 tester — engine layout detection works PRE-BUILD        ║
# ║                                                                  ║
# ║ Regression guard for the "first-ever ship of a v2 service        ║
# ║ deploys to wrong compose path" bug:                              ║
# ║                                                                  ║
# ║   When dist/ does not yet exist, the engine MUST still detect    ║
# ║   that a v2 service (one whose src/flake.nix imports             ║
# ║   _shared/engine.nix) needs `compose/docker-compose.yml`, not    ║
# ║   the v1 flat `docker-compose.yml`. Otherwise step_compose       ║
# ║   fails on the VM with "no such file or directory".              ║
# ║                                                                  ║
# ║ Data-driven (FIRE RULE 3): walks every src/flake.nix in          ║
# ║ a_solutions/ and exercises the engine's detect_layout against    ║
# ║ a fresh (no-dist) state, asserting it returns the right path.    ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 1_configs/src/test/test_layout_detection_pre_build.sh   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENGINE="$REPO_ROOT/1_configs/src/scripts/cloud-ship-container-engine.sh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Engine layout detection works pre-build (no dist/) ──"

# Find one v2 service (imports _shared/engine.nix) and one v1 service (does
# not). Pick deterministically by sort order so the result is stable.
mapfile -t V2_FLAKES < <(grep -l "_shared/engine.nix" \
  "$REPO_ROOT"/a_solutions/*/src/flake.nix 2>/dev/null | sort | head -3)
mapfile -t ALL_FLAKES < <(find "$REPO_ROOT/a_solutions" -maxdepth 4 \
  -name flake.nix -not -path "*/z_archive/*" 2>/dev/null | sort)

V1_FLAKE=""
for f in "${ALL_FLAKES[@]}"; do
  if ! grep -q "_shared/engine.nix" "$f" 2>/dev/null; then
    V1_FLAKE="$f"
    break
  fi
done

if [ "${#V2_FLAKES[@]}" -eq 0 ]; then
  fail "no v2 services found (none import _shared/engine.nix)"
  exit 1
fi

# Spawn a fake build context with NO dist/ and assert detect_layout sets v2.
assert_layout() {
  local flake="$1" want_layout_v2="$2" want_compose_rel="$3" label="$4"
  local src_dir="$(dirname "$flake")"
  local svc_dir="$(dirname "$src_dir")"
  local fake_dist="$(mktemp -d)"
  trap 'rm -rf "$fake_dist"' RETURN

  # Source the engine in detection-only mode by extracting + invoking the
  # detect_layout function directly (avoids running its full ship pipeline).
  local result
  result=$(SRC_DIR="$src_dir" DIST_DIR="$fake_dist" bash -c '
    set -e
    # Extract just the function from the engine — no side effects.
    eval "$(awk "/^detect_layout\\(\\) \\{/,/^\\}/" "$0")"
    detect_layout
    echo "LAYOUT_V2=$LAYOUT_V2"
    echo "REMOTE_COMPOSE_REL=$REMOTE_COMPOSE_REL"
  ' "$ENGINE" 2>&1)

  local got_layout_v2 got_compose_rel
  got_layout_v2=$(echo "$result" | awk -F= '/^LAYOUT_V2=/{print $2}')
  got_compose_rel=$(echo "$result" | awk -F= '/^REMOTE_COMPOSE_REL=/{print $2}')

  if [ "$got_layout_v2" != "$want_layout_v2" ] || [ "$got_compose_rel" != "$want_compose_rel" ]; then
    fail "$label: expected LAYOUT_V2=$want_layout_v2 REMOTE_COMPOSE_REL=$want_compose_rel — got LAYOUT_V2=$got_layout_v2 REMOTE_COMPOSE_REL=$got_compose_rel"
  else
    pass "$label: LAYOUT_V2=$got_layout_v2 → $got_compose_rel"
  fi
}

# Pre-build: v2 services must still detect as v2 (the actual bug)
for v2 in "${V2_FLAKES[@]}"; do
  rel=${v2#"$REPO_ROOT/"}
  svc=$(basename "$(dirname "$(dirname "$v2")")")
  assert_layout "$v2" "1" "compose/docker-compose.yml" "v2 service '$svc' (no dist/) → v2"
done

# v1 service (or no flake) must NOT auto-promote to v2
if [ -n "$V1_FLAKE" ]; then
  svc=$(basename "$(dirname "$(dirname "$V1_FLAKE")")")
  assert_layout "$V1_FLAKE" "0" "docker-compose.yml" "v1 service '$svc' (no dist/) → v1"
fi

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "Phase 15 layout detection: PASS"
  exit 0
else
  echo ""
  echo "Phase 15 layout detection: FAIL"
  exit 1
fi
