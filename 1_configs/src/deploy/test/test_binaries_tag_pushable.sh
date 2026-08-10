#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Static assertion — SSH remote-build materialises -binaries tag   ║
# ║                                                                  ║
# ║ Proves that the ssh) RUNNER_TYPE branch in the build-docker      ║
# ║ engine guarantees $BINARIES_IMAGE tag exists in the remote       ║
# ║ builder's local image store BEFORE `docker push $BINARIES_IMAGE` ║
# ║ is called.                                                       ║
# ║                                                                  ║
# ║ Background: BuildKit classic `docker build -t A -t B` names both ║
# ║ tags during the build ("naming to B done") but may only          ║
# ║ materialise the first --tag alias in the daemon store. The       ║
# ║ subsequent `docker push B` then fails with "An image does not    ║
# ║ exist locally with the tag" → exit 1 → ship aborts before        ║
# ║ deploy (my-ai-api, 2026-07-29). Fix: drop the second --tag from  ║
# ║ the docker build line and add an explicit `docker tag A B` step  ║
# ║ immediately after the build, before the push.                    ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_binaries_tag_pushable.sh   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOCKER_STEP="$REPO_ROOT/1_configs/src/deploy/scripts/cloud-ship-container-step-build-docker.sh"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── A: ssh) branch builds with only \$FULL_IMAGE tag (not -t \$BINARIES_IMAGE) ──"

# The docker build line inside the SSH heredoc must NOT carry -t $BINARIES_IMAGE.
# If it does, BuildKit may name the alias without materialising it in the daemon
# store, making the subsequent push unpushable.
if awk '
    /ssh_with_retry "\$RUNNER_HOST".*mkdir.*JOB_CMD/,/^EOF$/ {
        if (/docker build/ && /-t \$BINARIES_IMAGE/) { found=1 }
    }
    END { exit (found ? 0 : 1) }
' "$DOCKER_STEP"; then
    fail "ssh) docker build still carries -t \$BINARIES_IMAGE (BuildKit may not materialise it)"
else
    pass "ssh) docker build does not carry -t \$BINARIES_IMAGE"
fi

echo ""
echo "── B: ssh) branch has explicit docker tag before docker push \$BINARIES_IMAGE ──"

# Inside the SSH heredoc (between the `cat > $JOB_CMD` heredoc markers), there
# must be a `docker tag $FULL_IMAGE:$_ptag $BINARIES_IMAGE:$_btag` line that
# appears BEFORE `docker push $BINARIES_IMAGE`.
if awk '
    /ssh_with_retry "\$RUNNER_HOST".*mkdir.*JOB_CMD/,/^EOF$/ {
        if (/docker tag \$FULL_IMAGE:\$_ptag \$BINARIES_IMAGE:\$_btag/) { saw_tag=1 }
        if (/docker push \$BINARIES_IMAGE:\$_btag/ && saw_tag)          { saw_push_after_tag=1 }
    }
    END { exit (saw_push_after_tag ? 0 : 1) }
' "$DOCKER_STEP"; then
    pass "ssh) branch: docker tag \$FULL_IMAGE → \$BINARIES_IMAGE before push"
else
    fail "ssh) branch: missing docker tag \$FULL_IMAGE → \$BINARIES_IMAGE before docker push \$BINARIES_IMAGE"
fi

echo ""
echo "── C: \$FULL_IMAGE push still present (main image push not removed) ──"

if grep -q 'docker push \$FULL_IMAGE:\$_ptag' "$DOCKER_STEP"; then
    pass "\$FULL_IMAGE push retained"
else
    fail "\$FULL_IMAGE push line missing — working services would break"
fi

echo ""
echo "── D: fix comment present (documents root cause) ──"

if grep -q 'binaries-tag fix' "$DOCKER_STEP"; then
    pass "root-cause comment present"
else
    fail "root-cause comment missing"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "test_binaries_tag_pushable: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "test_binaries_tag_pushable: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
