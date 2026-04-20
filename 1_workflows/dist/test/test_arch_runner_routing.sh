#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 1 tester — arch → runner routing                           ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   1. cloud-data-runners.json has an entry for every docker.arch  ║
# ║      declared by any build.json                                  ║
# ║   2. step_docker reads from the JSON (no hardcoded oci-apps)     ║
# ║   3. The illegal QEMU fallback branch is gone                    ║
# ║   4. Unreachable ssh runner → engine exits 1 (no silent fallback)║
# ║                                                                  ║
# ║ Usage: bash 1_workflows/src/test/test_arch_runner_routing.sh     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/1_workflows/src/scripts"
DOCKER_STEP="$SCRIPTS/cloud-ship-container-step-build-docker.sh"
DISPATCH="$SCRIPTS/cloud-ship-ci-builder-dispatch.sh"

RUNNERS_JSON=""
for p in \
    "$REPO_ROOT/I_cloud-data/cloud-data-runners.json" \
    "$REPO_ROOT/cloud-data-runners.json"; do
    [ -f "$p" ] && { RUNNERS_JSON="$p"; break; }
done

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── 1: runners.json exists and matches every declared docker.arch ──"

if [ -z "$RUNNERS_JSON" ]; then
    fail "cloud-data-runners.json not found under I_cloud-data/ or repo root"
else
    pass "runners.json found at $RUNNERS_JSON"
    # Collect distinct docker.arch values from every service build.json
    declared_arches=$(find "$REPO_ROOT/a_solutions" -maxdepth 2 -name build.json \
        -not -path "*/z_archive/*" -print0 2>/dev/null \
        | xargs -0 -I{} jq -r '.docker.arch // empty' {} 2>/dev/null \
        | sort -u | grep -v '^$' || true)
    for arch in $declared_arches; do
        if jq -e --arg a "$arch" '.runners[$a].type' "$RUNNERS_JSON" >/dev/null 2>&1; then
            pass "runners.json has entry for arch=$arch"
        else
            fail "arch=$arch declared by a service but missing in runners.json"
        fi
    done
fi

echo ""
echo "── 2: step_docker reads from runners.json, no hardcoded hostnames ──"

if grep -q 'cloud-data-runners.json' "$DOCKER_STEP"; then
    pass "step_docker reads cloud-data-runners.json"
else
    fail "step_docker does NOT reference cloud-data-runners.json"
fi

# Hardcoded hostnames must not appear outside the runners.json comment/context
if grep -E '"oci-apps"|oci-apps-1|oci-apps-2' "$DOCKER_STEP" | grep -vE '#|runners|JSON' >/dev/null; then
    fail "hardcoded hostnames still present in step_docker:"
    grep -nE '"oci-apps"|oci-apps-1|oci-apps-2' "$DOCKER_STEP" | grep -vE '#|runners|JSON' >&2 || true
else
    pass "no hardcoded oci-apps hostnames in step_docker"
fi

if grep -q 'ghcr.io/diegonmarcos/cloud-builder-x' "$DOCKER_STEP"; then
    fail "step_docker still hardcodes builder_image — must come from runners.json"
else
    pass "builder_image is not hardcoded in step_docker"
fi

echo ""
echo "── 3: illegal QEMU branch removed ──"

# Match executable code only — skip comment lines (#…) and pure-text "No QEMU" mentions.
if grep -niE 'qemu|cross-compile' "$DOCKER_STEP" \
    | grep -vE '^\s*[0-9]+:\s*#' \
    | grep -viE 'no\s+qemu|no\s+cross-compile' \
    | grep -q .; then
    fail "QEMU/cross-compile executable code still present in step_docker:"
    grep -niE 'qemu|cross-compile' "$DOCKER_STEP" \
        | grep -vE '^\s*[0-9]+:\s*#' \
        | grep -viE 'no\s+qemu|no\s+cross-compile' >&2 || true
else
    pass "no QEMU / cross-compile executable code in step_docker"
fi

echo ""
echo "── 4: unreachable ssh runner causes engine to exit 1 ──"

# Smoke-test the guard path: synthesize a temp runners.json with an
# unreachable host, source step_docker, stub log()/log_error()/ssh, call it.
tmp=$(mktemp -d)
cp "$RUNNERS_JSON" "$tmp/runners.json"
jq '.runners.arm64.host = "nonexistent-host.invalid"' "$RUNNERS_JSON" > "$tmp/runners.json.new"
mv "$tmp/runners.json.new" "$tmp/runners.json"

if bash -c "
    set -u
    log() { :; }
    log_error() { printf 'ERR: %s\n' \"\$1\" >&2; }
    get_config() { echo ''; }
    SERVICE_NAME=fake
    SERVICE_DIR=$tmp
    SRC_DIR=$tmp
    DIST_DIR=$tmp
    CLOUD_ROOT=$tmp
    mkdir -p $tmp/I_cloud-data
    cp $tmp/runners.json $tmp/I_cloud-data/cloud-data-runners.json
    DOCKER_IMAGE=ghcr.io/x/fake
    DOCKER_REGISTRY=
    DOCKER_ARCH=arm64
    DEPLOY_HOST=
    DEPLOY_PATH=
    SSH_OPTS=
    # Stub ssh so the live probe fails
    ssh() { return 255; }
    . $DOCKER_STEP
    step_docker
" 2>"$tmp/err"; then
    fail "step_docker should have exited non-zero when arm64 runner is unreachable"
    cat "$tmp/err" >&2
else
    if grep -q 'unreachable\|illegal state' "$tmp/err"; then
        pass "unreachable runner produces fail-loud error"
    else
        fail "step_docker exited non-zero but not with the expected 'unreachable' message:"
        cat "$tmp/err" >&2
    fi
fi
rm -rf "$tmp"

echo ""
echo "── 5: dispatch warms cross-arch runners ──"

if grep -q 'CLOUD_BUILDER_.*_READY' "$DISPATCH"; then
    pass "dispatch exports CLOUD_BUILDER_<ARCH>_READY flag"
else
    fail "dispatch does not export cross-arch readiness flag"
fi

if grep -q '.runners\[\$a\].type' "$DISPATCH"; then
    pass "dispatch reads runner map from runners.json"
else
    fail "dispatch does not read from runners.json"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 1 arch routing: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 1 arch routing: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
