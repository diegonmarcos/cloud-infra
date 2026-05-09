#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_ship_cargo_cache.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ ship-pipeline cargo cache wiring test (D2)                       ║
# ║                                                                  ║
# ║ Asserts ship.yml warms a Rust cargo cache so subsequent ship     ║
# ║ runs can skip `cargo download crates` + `cargo build` from-scratch║
# ║ for fin-api, mail-puller, rig-agentic-*, http-to-smtp-proxy-api, etc. ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   1. ship.yml has an actions/cache@v4 step keyed on Cargo.lock   ║
# ║   2. The cache step covers ~/.cargo/registry, ~/.cargo/git, and  ║
# ║      a runner-temp cargo-target dir.                             ║
# ║   3. The cloud-builder docker compose run mounts the host cargo  ║
# ║      cache + sets CARGO_HOME and CARGO_TARGET_DIR env vars.      ║
# ║   4. Docker layer cache (already wired in build-docker step) is  ║
# ║      still in place: --cache-from in the docker build line.      ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_ship_cargo_cache.sh        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SHIP_YML="$REPO_ROOT/1_workflows/src/cicd/ship.yml"
DOCKER_BUILD_SH="$REPO_ROOT/1_workflows/src/scripts/cloud-ship-container-step-build-docker.sh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

[ -f "$SHIP_YML" ] || { echo "FATAL: missing $SHIP_YML" >&2; exit 1; }
[ -f "$DOCKER_BUILD_SH" ] || { echo "FATAL: missing $DOCKER_BUILD_SH" >&2; exit 1; }

echo "── 1: ship.yml has actions/cache@v4 step for cargo ──"
if grep -q "actions/cache@v4" "$SHIP_YML" && grep -q "cargo" "$SHIP_YML"; then
  pass "actions/cache@v4 + cargo references present"
else
  fail "missing actions/cache@v4 or cargo cache step"
fi

echo "── 2: cache covers registry + git + target ──"
COVERED=0
grep -q "cargo/registry" "$SHIP_YML" && COVERED=$((COVERED + 1))
grep -q "cargo/git"      "$SHIP_YML" && COVERED=$((COVERED + 1))
grep -q "cargo-target"   "$SHIP_YML" && COVERED=$((COVERED + 1))
if [ "$COVERED" -eq 3 ]; then
  pass "registry + git + target all present in cache step"
else
  fail "expected registry + git + target in cache; got $COVERED/3"
fi

echo "── 3: cache is keyed on Cargo.lock hashes ──"
if grep -q 'hashFiles.*Cargo\.lock' "$SHIP_YML"; then
  pass "cache key includes Cargo.lock hash"
else
  fail "cache key does not hash Cargo.lock — restoration will be unreliable"
fi

echo "── 4: cloud-builder docker run mounts cargo cache + sets env ──"
HAS_CARGO_MOUNT=$(grep -c '/root/.cargo' "$SHIP_YML" || true)
HAS_TARGET_MOUNT=$(grep -c '/cargo-target' "$SHIP_YML" || true)
HAS_CARGO_HOME=$(grep -c 'CARGO_HOME=/root/.cargo' "$SHIP_YML" || true)
HAS_CARGO_TARGET_ENV=$(grep -c 'CARGO_TARGET_DIR=/cargo-target' "$SHIP_YML" || true)
if [ "$HAS_CARGO_MOUNT" -ge 1 ] && [ "$HAS_TARGET_MOUNT" -ge 1 ] && [ "$HAS_CARGO_HOME" -ge 1 ] && [ "$HAS_CARGO_TARGET_ENV" -ge 1 ]; then
  pass "cloud-builder run mounts cargo home + target + sets both env vars"
else
  fail "cloud-builder run is missing cargo mounts/env (mount=$HAS_CARGO_MOUNT, target=$HAS_TARGET_MOUNT, CARGO_HOME=$HAS_CARGO_HOME, CARGO_TARGET_DIR=$HAS_CARGO_TARGET_ENV)"
fi

echo "── 5: Docker layer cache (--cache-from) is wired in build-docker step ──"
if grep -q "cache-from" "$DOCKER_BUILD_SH"; then
  pass "--cache-from present in cloud-ship-container-step-build-docker.sh"
else
  fail "--cache-from missing — docker build will not reuse layers"
fi

echo "── 6: BuildKit enabled for the local docker build branch ──"
if grep -q "DOCKER_BUILDKIT=1" "$DOCKER_BUILD_SH"; then
  pass "DOCKER_BUILDKIT=1 enabled"
else
  fail "DOCKER_BUILDKIT not enabled — will fall back to legacy builder"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "════════════════════════════════════════════"
  echo "ship-pipeline cache wiring (D2): PASS"
  echo "════════════════════════════════════════════"
  exit 0
else
  echo "════════════════════════════════════════════"
  echo "ship-pipeline cache wiring (D2): FAIL"
  echo "════════════════════════════════════════════"
  exit 1
fi
