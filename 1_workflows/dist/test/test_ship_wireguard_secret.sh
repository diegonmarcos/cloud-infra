#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 6 tester — ship.yml passes WG_PRIVATE_KEY                  ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   Every ship workflow that targets VMs reachable only via        ║
# ║   WireGuard (wg_ip: 10.0.0.0/24) must pass WG_PRIVATE_KEY to     ║
# ║   the cloud-builder container, so entrypoint.sh brings wg0 up    ║
# ║   and *.wg_ip resolves. Without it, every ssh to a WG-only VM    ║
# ║   times out (root cause of the 2026-04-20 oci-mail ship fails).  ║
# ║                                                                  ║
# ║   Data-driven: iterate cloud-data-gha-config.json; any VM with   ║
# ║   a wg_ip requires the workflows that target it to forward the   ║
# ║   secret.                                                         ║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_ship_wireguard_secret.sh   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GHA_CONFIG="$REPO_ROOT/2_configs/dist/cloud-data-gha-config.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Any VM with wg_ip requires ship.yml to pass WG_PRIVATE_KEY ──"

if [ ! -f "$GHA_CONFIG" ]; then
    echo "  (2_configs/dist not present — nothing to assert)"
    exit 0
fi

# Data-driven: list VMs whose reachability depends on WG (have wg_ip).
_wg_vms=$(jq -r '.vms | to_entries[] | select(.value.wg_ip) | .key' "$GHA_CONFIG")
if [ -z "$_wg_vms" ]; then
    pass "no VMs declare wg_ip — nothing to enforce"
else
    pass "VMs requiring WG: $(echo $_wg_vms | tr '\n' ' ')"
fi

# Workflows that matrix over those VMs must pass WG_PRIVATE_KEY.
for wf in "$REPO_ROOT"/1_workflows/src/cicd/ship.yml \
          "$REPO_ROOT"/1_workflows/src/cicd/ship-home-manager.yml; do
    [ -f "$wf" ] || continue
    name=$(basename "$wf")
    if grep -qE '^\s*WG_PRIVATE_KEY:\s*\$\{\{\s*secrets\.WG_PRIVATE_KEY\s*\}\}' "$wf"; then
        pass "$name passes WG_PRIVATE_KEY"
    else
        fail "$name does NOT pass WG_PRIVATE_KEY (WG-only VMs will time out)"
    fi
done

echo ""
echo "── cloud-builder entrypoint brings WG up when the key is set ──"

# Source of truth lives in unix submodule
ENTRYPOINT=""
for base in \
    "$REPO_ROOT/III_unix/cb_containers-builders/src/docker" \
    "$REPO_ROOT/a_solutions/bd-cloud-builder-x/src/docker"; do
    if [ -f "$base/entrypoint.sh" ]; then
        ENTRYPOINT="$base/entrypoint.sh"
        break
    fi
done

if [ -z "$ENTRYPOINT" ]; then
    echo "  (III_unix not present — skipping entrypoint check)"
else
    if grep -qE 'WG_PRIVATE_KEY' "$ENTRYPOINT" && grep -qE 'wg-quick up' "$ENTRYPOINT"; then
        pass "entrypoint.sh brings wg0 up when WG_PRIVATE_KEY is set"
    else
        fail "entrypoint.sh does not run wg-quick up — WG never comes up in container"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 6 WG secret propagation: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 6 WG secret propagation: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
