#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_ship_workflows_dual_trigger.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: every Ship → * workflow (except gen-configs itself) MUST have:
#   1. on: push:    direct trigger on its own path filter (auto-deploy on src changes)
#   2. on: workflow_run:    cascade after gen-configs SUCCESS (canonical-truth ordering)
#   3. on: workflow_dispatch:    manual trigger
#   4. job-level if: gating workflow_run.conclusion == 'success'
#
# Regression this guards against (introduced 2026-05-06 in 8ab8dd832, fixed in
# 815fb0f54): gating ship.yml on workflow_run-only meant src/ commits stopped
# auto-shipping because gen-configs only fires on declaration changes, not
# service code. A maddy src/ edit no longer auto-deployed.
#
# This test catches it at compile time — `bash 1_configs/build.sh build` will
# call this in dist/ regen testing if invoked, OR run directly:
#   bash 1_configs/src/test/test_ship_workflows_dual_trigger.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WF_DIR="$REPO_ROOT/.github/workflows"

# ship-gen-configs is the head of the cascade — it does NOT depend on itself,
# so it's exempt from the dual-trigger rule (push-only is correct).
EXEMPT="ship-gen-configs.yml"

PASS=0
FAIL=0
report() {
    local kind="$1" file="$2" msg="$3"
    case "$kind" in
        pass) printf "  ✓ %s — %s\n" "$file" "$msg"; PASS=$((PASS+1)) ;;
        fail) printf "  ✗ %s — %s\n" "$file" "$msg" >&2;  FAIL=$((FAIL+1)) ;;
    esac
}

echo "═══ test_ship_workflows_dual_trigger ═══"
echo "Asserting every Ship → * workflow (except gen-configs) has BOTH push: + workflow_run: triggers"
echo

for f in "$WF_DIR"/ship*.yml; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ "$base" = "$EXEMPT" ] && { echo "  · $base — exempt (head of cascade, push-only is correct)"; continue; }

    # Test 1: push: trigger present
    if grep -q '^  push:' "$f"; then
        report pass "$base" "has on: push:"
    else
        report fail "$base" "MISSING on: push:  — src/ changes won't auto-ship"
    fi

    # Test 2: workflow_run: trigger present
    if grep -q '^  workflow_run:' "$f"; then
        report pass "$base" "has on: workflow_run:"
    else
        report fail "$base" "MISSING on: workflow_run:  — declaration changes won't cascade"
    fi

    # Test 3: workflow_dispatch present (manual trigger)
    if grep -q '^  workflow_dispatch:' "$f"; then
        report pass "$base" "has on: workflow_dispatch:"
    else
        report fail "$base" "MISSING on: workflow_dispatch:  — no manual trigger"
    fi

    # Test 4: job-level if-gate on workflow_run conclusion
    # Pattern allows either format:
    #   if: ${{ github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success' }}
    if grep -qE "github\.event_name *!= *'workflow_run'.*conclusion *== *'success'" "$f"; then
        report pass "$base" "has if-gate on workflow_run.conclusion == 'success'"
    else
        report fail "$base" "MISSING if-gate — failed gen-configs runs won't be filtered out"
    fi

    # Test 5: workflow_run lists ship-gen-configs as upstream
    if grep -qE 'workflows: *\["?Ship → gen-configs' "$f"; then
        report pass "$base" "workflow_run depends on Ship → gen-configs"
    else
        report fail "$base" "MISSING workflow_run dependency on Ship → gen-configs"
    fi
done

echo
echo "─── summary ───"
printf "  pass: %d\n  fail: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  all ship-* workflows correctly wired for dual-trigger cascade"
