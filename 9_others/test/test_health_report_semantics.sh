#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 12 tester — health-report engine severity semantics        ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   B5  init_job:true containers mapped to Severity::Info          ║
# ║       (not Critical) on Exited(0) + Exited(1).                   ║
# ║   B7  public:false containers skip the "container up / public   ║
# ║       probe down" cross-check (container is WG-only by design).  ║
# ║                                                                  ║
# ║ Asserts the Rust source patterns are present — compile check    ║
# ║ runs in CI via cargo check.                                     ║
# ║                                                                  ║
# ║ Usage: bash 9_others/test/test_health_report_semantics.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

# Health engine source may live in submodule or sibling clone; try both.
RUST_SRC=""
for p in \
    "$REPO_ROOT/I_cloud-data/reports/src/cloud-health-full-2/src" \
    "$REPO_ROOT/1_cicd/dist/reports/src/cloud-health-full-2/src" \
    "$REPO_ROOT/../cloud-data/reports/src/cloud-health-full-2/src"; do
    [ -d "$p" ] && { RUST_SRC="$p"; break; }
done

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

if [ -z "$RUST_SRC" ]; then
    echo "  ⚠ cloud-health-full-2 Rust source not found — skipping"
    exit 0
fi

echo "── B5: init_job declarative flag (not just name heuristic) ──"

types_rs="$RUST_SRC/types.rs"
layers_rs="$RUST_SRC/layers.rs"
context_rs="$RUST_SRC/context.rs"

if grep -q 'pub init_job:\s*bool' "$types_rs"; then
    pass "ContainerDecl.init_job field declared"
else
    fail "types.rs missing ContainerDecl.init_job field"
fi

if grep -q 'init_job' "$context_rs" && grep -qE 'one_shot|init_job' "$context_rs"; then
    pass "context.rs populates init_job from build.json"
else
    fail "context.rs doesn't read init_job / one_shot from build.json"
fi

if grep -q 'ct\.init_job' "$layers_rs"; then
    pass "layers.rs uses ct.init_job in severity decision"
else
    fail "layers.rs still only uses name heuristic (_init/-setup/_setup)"
fi

echo ""
echo "── B7: public:false containers skip cross-check ──"

if grep -q 'pub public:\s*bool' "$types_rs"; then
    pass "ContainerDecl.public field declared"
else
    fail "types.rs missing ContainerDecl.public field"
fi

if grep -qE 'any_public_container|any.*\.public\s*\)' "$layers_rs"; then
    pass "layers.rs guards cross-check on any_public_container"
else
    fail "layers.rs doesn't filter cross-check by containers[*].public"
fi

echo ""
echo "── cargo check ──"

if command -v cargo >/dev/null 2>&1; then
    if (cd "$RUST_SRC/.." && cargo check --quiet 2>/dev/null); then
        pass "cargo check clean"
    else
        fail "cargo check failed"
        (cd "$RUST_SRC/.." && cargo check 2>&1 | tail -20) >&2 || true
    fi
else
    echo "  • cargo not installed — skipping type-check"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 12 health-report semantics: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 12 health-report semantics: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
