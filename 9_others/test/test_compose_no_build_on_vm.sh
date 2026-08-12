#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 19 tester — VMs MUST NEVER rebuild containers              ║
# ║                                                                  ║
# ║ All images are pre-built + pushed to GHCR by the engine          ║
# ║ (step_docker). The deploy VM should only PULL — rebuilding on    ║
# ║ a 1GB e2-micro VM (or under load) OOMs the host and breaks       ║
# ║ unrelated containers.                                            ║
# ║                                                                  ║
# ║ This phase enforces the compose-up policy by inspecting the      ║
# ║ engine source: the deploy-compose step MUST always include       ║
# ║ `--no-build` in COMPOSE_UP_FLAGS, with no branch that flips      ║
# ║ to `--build`.                                                    ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 9_others/test/test_compose_no_build_on_vm.sh       ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
ENGINE="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Compose-up step MUST always use --no-build (no VM rebuilds) ──"

if [ ! -f "$ENGINE" ]; then
    fail "engine script not found: $ENGINE"
    exit 1
fi

# 1) The default COMPOSE_UP_FLAGS line includes --no-build
if grep -q 'COMPOSE_UP_FLAGS="--no-build' "$ENGINE"; then
    pass "default COMPOSE_UP_FLAGS includes --no-build"
else
    fail "default COMPOSE_UP_FLAGS missing --no-build in $ENGINE"
fi

# 2) NO active assignment that sets COMPOSE_UP_FLAGS to --build (uncommented)
if grep -E '^[[:space:]]*COMPOSE_UP_FLAGS="--build' "$ENGINE" >/dev/null 2>&1; then
    fail "engine still has an active assignment of COMPOSE_UP_FLAGS=\"--build...\" — VM rebuild path is reachable"
else
    pass "no active COMPOSE_UP_FLAGS=\"--build...\" assignment"
fi

# 3) The shipped `up -d` invocation in compose-custom + standard branches
#    must reference $COMPOSE_UP_FLAGS (not a literal --build).
if grep -E '^[[:space:]]*echo .*up -d.*--build' "$ENGINE" >/dev/null 2>&1; then
    fail "literal '--build' present in compose-up emission"
else
    pass "compose-up uses \$COMPOSE_UP_FLAGS variable (no literal --build)"
fi

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "Phase 19 compose --no-build: PASS"
    exit 0
else
    echo ""
    echo "Phase 19 compose --no-build: FAIL"
    exit 1
fi
