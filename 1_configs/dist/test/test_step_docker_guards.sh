#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/test/test_step_docker_guards.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 2 tester — step_docker guards                              ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) step_docker returns 0 + logs "skipping" when docker.image   ║
# ║      is absent (authelia / hickory-dns / umami use inline only)  ║
# ║   A) the guard accepts BOTH ""  and "null" (jq literal)          ║
# ║   G) for type=binary, the engine runs NATIVE_CMD before checking ║
# ║      that the binary exists (fixes http-to-smtp-proxy-api)       ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_step_docker_guards.sh      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOCKER_STEP="$REPO_ROOT/1_configs/src/deploy/scripts/cloud-ship-container-step-build-docker.sh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── A1: stronger guard — skip when no Dockerfile AND no NATIVE_CMD ──"

# The dockerfile_inline case: DOCKER_IMAGE set, DOCKERFILE_PATH missing,
# NATIVE_CMD empty → step_docker must skip (compose-build owns the image).
if grep -q 'compose-build owns image' "$DOCKER_STEP" \
   && grep -q '! -f "\$DOCKERFILE_PATH" \] && \[ -z "\$NATIVE_CMD"' "$DOCKER_STEP"; then
    pass "step_docker skips when DOCKERFILE_PATH missing + no NATIVE_CMD"
else
    fail "step_docker lacks the dockerfile_inline skip guard"
fi

echo ""
echo "── A: step_docker skip guard covers '' and 'null' ──"

# Source the step in a sub-shell with stubs and test two inputs
run_case() {
    local img="$1" expected_msg="$2"
    bash -c "
        set -u
        log() { printf 'LOG: %s\n' \"\$1\"; }
        log_error() { printf 'ERR: %s\n' \"\$1\" >&2; }
        get_config() { echo ''; }
        DOCKER_IMAGE='$img'
        DOCKER_REGISTRY=
        DOCKER_ARCH=amd64
        SERVICE_DIR=/tmp
        SRC_DIR=/tmp
        DIST_DIR=/tmp
        DEPLOY_HOST=
        DEPLOY_PATH=
        SERVICE_NAME=fake
        . $DOCKER_STEP
        step_docker
    " 2>&1
}

for val in "" "null"; do
    out=$(run_case "$val" "skipping" || true)
    if echo "$out" | grep -q 'LOG: No docker.image in build.json -- skipping'; then
        pass "guard skips for DOCKER_IMAGE='$val'"
    else
        fail "guard did not skip for DOCKER_IMAGE='$val' — got:"
        echo "$out" >&2
    fi
done

echo ""
echo "── G: type=binary runs NATIVE_CMD before checking for binary ──"

# The source must contain an `eval \"\$NATIVE_CMD\"` call BEFORE the
# "Native build produced no binary" error path, inside the `else` branch
# for type=binary (i.e. after the `elif [ \"\$NATIVE_TYPE\" = \"app\" ]` block).
if awk '
    /^        else$/            { in_binary=1; next }
    in_binary && /eval "\$NATIVE_CMD"/ { found_eval=1 }
    in_binary && /Native build produced no binary/ {
        if (found_eval) { print "OK"; exit }
        else            { print "MISSING_EVAL"; exit }
    }
' "$DOCKER_STEP" | grep -q OK; then
    pass "type=binary branch runs NATIVE_CMD before binary check"
else
    fail "type=binary branch still lacks NATIVE_CMD invocation before binary check"
fi

# And CARGO_TARGET_DIR must be exported in that branch so cargo writes to
# a known path that the check can find.
if grep -q 'export CARGO_TARGET_DIR' "$DOCKER_STEP"; then
    pass "CARGO_TARGET_DIR is exported for type=binary"
else
    fail "CARGO_TARGET_DIR not exported — binary check will miss cargo output"
fi

# The error message must not have a trailing empty parenthesis
if grep -q 'also checked )' "$DOCKER_STEP"; then
    fail "error message has trailing '(also checked )' with empty content"
else
    pass "error message references the actual cargo binary path"
fi

echo ""
echo "── A+G: shellcheck step_docker (sourced, force --shell=bash) ──"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error --shell=bash -x "$DOCKER_STEP" >/dev/null 2>&1; then
        pass "shellcheck clean: $(basename "$DOCKER_STEP")"
    else
        fail "shellcheck errors in $(basename "$DOCKER_STEP"):"
        shellcheck -S error --shell=bash -x "$DOCKER_STEP" >&2 || true
    fi
else
    echo "  ⚠ shellcheck not installed — skipping static check"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 2 step_docker guards: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 2 step_docker guards: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
