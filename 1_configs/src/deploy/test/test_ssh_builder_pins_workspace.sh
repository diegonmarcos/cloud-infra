#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 29 tester — SSH-builder docker run pins cwd to /workspace  ║
# ║                                                                   ║
# ║ Failure mode this catches (proven 2026-04-27 ship run             ║
# ║ 25000440517): step_docker uses `docker run … -w /workspace        ║
# ║ <image> sh -c '<build>'`. cloud-builder-x's entrypoint            ║
# ║ (cb_containers-builders/src/docker/entrypoint.sh:248-249) does    ║
# ║ `cd $GIT_ROOT/cloud` before exec'ing the bash|sh dispatch case,   ║
# ║ OVERRIDING docker's -w flag. Without an explicit `cd /workspace`  ║
# ║ in the sh -c payload, docker build runs from /root/git/cloud and  ║
# ║ can't find the engine-generated Dockerfile.native (rsync'd to     ║
# ║ /workspace). Result: "ERROR: failed to read dockerfile".          ║
# ║                                                                   ║
# ║ Phase 29 enforces the invariant statically: any SSH-builder       ║
# ║ docker-run heredoc/string in step_docker.sh that mounts a         ║
# ║ workspace dir MUST also `cd` into it before docker build.         ║
# ║ Belt-and-braces against entrypoint cwd drift.                     ║
# ║                                                                   ║
# ║ Data-driven (FIRE RULE 4): the path is extracted from             ║
# ║ step_docker.sh's `-v $REMOTE_BUILD_DIR:<MOUNT>` token; the test   ║
# ║ then asserts `cd <MOUNT>` appears in the same command block.      ║
# ║                                                                   ║
# ║ Fix when this fails:                                              ║
# ║   prepend `cd <mount> &&` to the sh -c payload (see commit        ║
# ║   141f67633 for the canonical form).                              ║
# ║                                                                   ║
# ║ Usage: bash 1_configs/src/deploy/test/test_ssh_builder_pins_workspace.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/1_configs/src/deploy/scripts/cloud-ship-container-step-build-docker.sh"

[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── SSH-builder docker run pins cwd to its mounted workspace ──"

# 1) Extract the workspace mount target. step_docker mounts the rsync
#    staging dir via `-v $REMOTE_BUILD_DIR:<MOUNT>`. Must be exactly one
#    such mount. Today: /workspace (from line 356).
MOUNT=$(grep -oE '\-v[[:space:]]+\$REMOTE_BUILD_DIR:[^[:space:]]+' "$SCRIPT" \
        | head -1 | sed -E 's|.*\$REMOTE_BUILD_DIR:([^ ]+)|\1|')
if [ -z "$MOUNT" ]; then
    fail "no \$REMOTE_BUILD_DIR mount found in $SCRIPT (engine layout drifted)"
    echo "Phase 29 ssh-builder-cwd: FAIL"
    exit 1
fi
pass "SSH-builder mounts \$REMOTE_BUILD_DIR -> $MOUNT"

# 2) `-w <MOUNT>` must be the docker working-dir (informational; entrypoint
#    can override but the engine must still declare intent).
if grep -qE "\-w[[:space:]]+${MOUNT}\b" "$SCRIPT"; then
    pass "docker run uses -w $MOUNT (declared intent)"
else
    fail "docker run does not declare -w $MOUNT — engine intent unclear"
fi

# 3) THE rule: the sh -c payload that follows the docker run must `cd $MOUNT`
#    before any docker build/login/push. The cloud-builder-x entrypoint may
#    cd elsewhere; -w is no protection. Explicit cd is the only safe form.
#
#    Find line numbers (in the file) of the SSH-builder `docker run …`,
#    `cd <MOUNT>`, and `docker build` and assert ordering. Substring search
#    via awk-block ran into multi-line edge cases; line-number ordering is
#    unambiguous.
DOCKER_RUN_LN=$(grep -nE 'ssh \$SSH_OPTS "\$RUNNER_HOST" "docker run' "$SCRIPT" | head -1 | cut -d: -f1)
CD_LN=$(awk -v m="cd $MOUNT" '
    # Skip comment-only lines (leading whitespace then #).
    /^[[:space:]]*#/ { next }
    index($0, m) > 0 { print NR; exit }
' "$SCRIPT")
BUILD_LN=$(awk '/docker build .*--cache-from/ { print NR; exit }' "$SCRIPT")

if [ -z "$DOCKER_RUN_LN" ]; then
    fail "no SSH-builder \`docker run\` line found — engine layout drifted"
elif [ -z "$CD_LN" ]; then
    fail "no \`cd $MOUNT\` line found in $SCRIPT — entrypoint cwd will leak through"
elif [ -z "$BUILD_LN" ]; then
    fail "no \`docker build --cache-from\` line found — engine layout drifted"
elif [ "$DOCKER_RUN_LN" -lt "$CD_LN" ] && [ "$CD_LN" -lt "$BUILD_LN" ]; then
    pass "sh -c payload runs \`cd $MOUNT\` (line $CD_LN) before \`docker build\` (line $BUILD_LN)"
else
    fail "ordering wrong: docker run=$DOCKER_RUN_LN, cd=$CD_LN, docker build=$BUILD_LN (expect run < cd < build)"
fi

if [ "$FAIL" -eq 0 ]; then
    echo
    echo "Phase 29 ssh-builder-cwd: PASS"
    exit 0
else
    echo
    echo "Phase 29 ssh-builder-cwd: FAIL — see commit 141f67633 for fix shape"
    exit 1
fi
