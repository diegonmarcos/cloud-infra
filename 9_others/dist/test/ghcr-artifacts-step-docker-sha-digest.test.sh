#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/ghcr-artifacts-step-docker-sha-digest.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Regression tests for PLAN-ghcr-artifacts.md item 1: step_docker pushes a
# reproducible <image>:<git-sha12> tag alongside :latest on every path
# (local buildx, local classic-degrade, remote ssh/arm64), captures the
# pushed digest best-effort, and degrades cleanly to the pre-existing
# classic `docker build` flow when the buildx plugin isn't available
# (neither builder image has shipped it historically — see the 2026-07-29
# regression comment this engine already carries).
#
# Mostly grep-level (mirrors test_step_docker_uses_cache.sh's style for the
# same file), plus one EXECUTED check: the buildx capability probe is small
# enough to extract and run against a stubbed `docker`, so a future rewrite
# that inverts the condition can't sneak past a grep.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-build-docker.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── 1) GIT_SHA12: GITHUB_SHA authoritative, git rev-parse the local fallback ──
ck "GITHUB_SHA is read for the reproducible tag" "$(grep -c 'GIT_SHA12="\${GITHUB_SHA:0:12}"' "$SCRIPT")" "1"
ck "git rev-parse is the local/dagu fallback"     "$(grep -c 'git -C .*rev-parse --short=12 HEAD' "$SCRIPT")" "1"

# ── 2) local branch: both the buildx path and the classic degrade path push sha12 ──
ck "buildx build carries the sha12 --tag"        "$(grep -c -- '--tag "\$FULL_IMAGE:\$GIT_SHA12"' "$SCRIPT")" "1"
ck "classic path: docker tag adds sha12 aliases" "$(grep -cE 'docker tag "\$FULL_IMAGE:\$_ptag" "\$FULL_IMAGE:\$GIT_SHA12"' "$SCRIPT")" "1"
ck "classic path: docker push ships the sha12 tags too" "$(grep -cE 'docker push "\$FULL_IMAGE:\$GIT_SHA12"' "$SCRIPT")" "1"

# ── 3) ssh (remote arm64) branch: sha12 tag+push spliced in, gated on GIT_SHA12 ──
ck "remote sha-tag fragment built controller-side"  "$(grep -c '_REMOTE_SHA_TAG_CMD="docker tag' "$SCRIPT")" "1"
ck "remote sha-push fragment built controller-side" "$(grep -c '_REMOTE_SHA_PUSH_CMD="docker push' "$SCRIPT")" "1"
ck "empty-GIT_SHA12 default keeps the && chain syntactically valid" "$(grep -c '_REMOTE_SHA_TAG_CMD="true && ' "$SCRIPT")" "1"

# ── 4) digest capture on every path (best-effort — see section 7 below) ──
ck "buildx captures digest via --metadata-file" "$(grep -c 'containerimage.digest' "$SCRIPT")" "1"
ck "classic path greps sha256 out of the push log (single-arch + multi-arch stitch)" \
   "$(grep -c "grep -oE 'sha256:\[0-9a-f\]{64}'" "$SCRIPT")" "2"
ck "multi-arch stitch re-captures digest from the manifest push (not a stale per-arch one)" \
   "$(grep -c 'Overwrites any per-arch _PUSHED_DIGEST' "$SCRIPT")" "1"
ck "remote script echoes a PUSHED_DIGEST marker line" "$(grep -c 'echo PUSHED_DIGEST=' "$SCRIPT")" "1"
ck "controller parses PUSHED_DIGEST back out of the polled tail" \
   "$(grep -c "sed -n 's/^PUSHED_DIGEST=//p'" "$SCRIPT")" "1"

# ── 5) buildx availability probe — EXECUTED against a stubbed docker, not grepped ──
awk '/^    _docker_buildx_ok\(\) \{/,/^    \}$/' "$SCRIPT" > "$T/fn.sh"
ck "buildx-probe function extracted" "$(grep -c '_docker_buildx_ok' "$T/fn.sh")" "1"
run_probe() { # $1 = stubbed exit code of `docker buildx version`
  ( docker() { [ "$1" = buildx ] && return "$RC"; return 0; }; RC="$1"; . "$T/fn.sh"; _docker_buildx_ok && echo yes || echo no )
}
ck "buildx present -> registry-cache path is taken"    "$(run_probe 0)" "yes"
ck "buildx absent  -> degrades to classic docker build" "$(run_probe 1)" "no"

# ── 6) BuildKit enabled for the classic invocation too (both local export and
#      the remote heredoc's inline prefix — two different machines/shells) ──
ck "DOCKER_BUILDKIT=1 exported for the local classic build" "$(grep -c 'export DOCKER_BUILDKIT=1' "$SCRIPT")" "1"
ck "remote classic build also gets DOCKER_BUILDKIT=1 (separate container -- the controller's export doesn't reach it)" \
   "$(grep -c 'DOCKER_BUILDKIT=1 docker build' "$SCRIPT")" "1"

# ── 7) never fails the push over digest/output plumbing — best-effort only ──
ck "digest JSON write is non-fatal"    "$(grep -c 'TRACE_DIR/digests/\${SERVICE_NAME}.json.*2>/dev/null || true' "$SCRIPT")" "1"
ck "GITHUB_OUTPUT write is non-fatal"  "$(grep -c 'GITHUB_OUTPUT" 2>/dev/null || true' "$SCRIPT")" "1"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
