#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_status_digest.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Phase 49 — `build.sh status` tells the truth about the running image digest
#
# THE DEFECT UNDER TEST (#357)
#
# step_status read the running digest with
#     docker inspect <container> | jq -r '.[0].RepoDigests[0] // ""'
# but `RepoDigests` is a property of the IMAGE. A CONTAINER inspect has no such
# key. jq does not error on that — `null | .[0]` is `null` — so `// ""` turned
# a structurally impossible read into an empty string, exit 0, no stderr.
#
# The empty digest then failed the `[ -n "$_dig" ]` arm and fell to `else`, so
# EVERY container running an image we push to GHCR was reported DRIFT. Not
# "unknown" — DRIFT. The verdict was not merely uncomputed, it was confidently
# wrong in the direction that says "re-ship me", and it had never once been
# right. That is why case 1 below is the load-bearing one: a perfectly in-sync
# container must be able to come back in-sync.
#
# The fix resolves the container's own `.Image` id and reads RepoDigests off
# the IMAGE, which also pins the comparison to the image that container is
# actually running rather than to wherever the tag points now.
#
# Both impure operations are injected (ssh_with_retry, docker), so this needs
# neither the fleet nor the network and is deterministic.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STEP="${STATUS_STEP_OVERRIDE:-$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-status.sh}"

[ -f "$STEP" ] || { echo "FAIL: $STEP missing"; exit 1; }

pass=0; fail=0
ck() {
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}
ck_has() {
  if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1: output did not contain '$3'"; fi
}
ck_hasnt() {
  if printf '%s' "$2" | grep -qF -- "$3"; then fail=$((fail+1)); echo "  FAIL $1: output must NOT contain '$3'"
  else pass=$((pass+1)); echo "  ok   $1"; fi
}
# The verdict for the container row specifically — last field of the row whose
# first field is the container name. Asserting on whole-output greps is not
# good enough here: the header carries "config: in-sync" and would satisfy any
# naive contains-check for a passing verdict.
verdict() { printf '%s\n' "$1" | awk '$1=="cloud-cgc-pub-mcp" {print $NF; exit}'; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REG_CURRENT="sha256:cc94f83cf3752770511a5a796cb995dbcfa81fc198d91435726e9e9ac4bb5130"
VM_STALE="sha256:23dc4f39dca0448da1b6885035f16a19c0292344d5cff9f86ee84d4171df1001"
IMG_ID="sha256:35d13d3817b365f41634c94b0ed2adfdc4f7425e8f42593a7174e854b45440a7"
OURS="ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries:latest"

mkdir -p "$WORK/dist" "$WORK/svc"
echo "dist-payload" > "$WORK/dist/file"
cat > "$WORK/svc/build.json" <<'JSON'
{ "containers": [ { "container_name": "cloud-cgc-pub-mcp" } ] }
JSON

# ── The harness: run step_status with both impure ops replaced ────────────
# CTR_REPODIGESTS  — a RepoDigests key planted on the CONTAINER inspect. Real
#                    Docker never emits one. It is here as a TRAP: code that
#                    reads the container object will find this value and must
#                    not, because it is not what the container is running.
# IMG_REPODIGESTS  — the JSON array the IMAGE inspect reports ("[]" = built on
#                    the VM, never pushed).
# REG_DIGESTS      — newline list the registry answers with ("" = silent).
run_status() {
  ( 
    set +e
    DEPLOY_HOST="testvm"; DEPLOY_PATH="/srv/svc"
    DIST_DIR="$WORK/dist"; SERVICE_DIR="$WORK/svc"; SERVICE_NAME="testsvc"
    DOCKER_REGISTRY="ghcr.io/diegonmarcos"
    CURRENT_STEP=""

    log()      { echo "$*"; }
    log_warn() { echo "WARN: $*"; }

    # stdin is deliberately NOT consumed, mirroring the real ssh.
    ssh_with_retry() {
      _host="$1"; _cmd="$2"
      case "$_cmd" in
        cat*.dist-hash*)
          find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16
          ;;
        "docker inspect "*)
          printf '[{"Id":"c0ffee","Name":"/cloud-cgc-pub-mcp","Image":"%s","Config":{"Image":"%s"},"State":{"Status":"running","Health":{"Status":"healthy"}}%s}]' \
            "$IMG_ID" "$OURS" "${CTR_REPODIGESTS:+,\"RepoDigests\":$CTR_REPODIGESTS}"
          ;;
        "docker image inspect "*)
          [ "${IMG_INSPECT_FAILS:-0}" = "1" ] && return 1
          printf '[{"Id":"%s","RepoDigests":%s}]' "$IMG_ID" "${IMG_REPODIGESTS:-[]}"
          ;;
        *) : ;;
      esac
    }

    # The registry seam. `docker manifest inspect` is asked for JSON with
    # .manifests[].digest; buildx is the second source the step consults.
    docker() {
      case "$1 ${2:-}" in
        "manifest inspect")
          [ -n "${REG_DIGESTS:-}" ] || return 1
          printf '%s\n' "$REG_DIGESTS" | jq -R . | jq -s '{manifests: map({digest: .})}'
          ;;
        "buildx imagetools") return 1 ;;
        *) return 1 ;;
      esac
    }

    . "$STEP"
    step_status
    echo "RC=$?"
  ) 2>&1
}

echo "── case 1: running digest == registry digest  →  in-sync (THE load-bearing case)"
out="$(CTR_REPODIGESTS="" \
       IMG_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$REG_CURRENT\"]" \
       REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "in-sync container reports in-sync"        "$(verdict "$out")" "in-sync"
ck_has  "in-sync run exits 0"                      "$out" "RC=0"
ck_has  "summary says RECONCILED"                  "$out" "RECONCILED"

echo "── case 2: running digest != registry digest  →  DRIFT"
out="$(CTR_REPODIGESTS="" \
       IMG_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$VM_STALE\"]" \
       REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "stale container reports DRIFT"            "$(verdict "$out")" "DRIFT"
ck_has  "drifted run exits non-zero"               "$out" "RC=1"

echo "── case 3: image has EMPTY RepoDigests (built on the VM) → UNDECIDABLE"
out="$(CTR_REPODIGESTS="" IMG_REPODIGESTS="[]" REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "unpublished image is UNDECIDABLE"         "$(verdict "$out")" "UNDECIDABLE"
ck_has  "undecidable says WHY, loudly"             "$out" "never pushed"
ck_has  "undecidable does not exit 0"              "$out" "RC=1"

echo "── case 4: registry will not answer → UNDECIDABLE, not in-sync"
out="$(CTR_REPODIGESTS="" \
       IMG_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$REG_CURRENT\"]" \
       REG_DIGESTS="" run_status)"
ck     "silent registry is UNDECIDABLE"           "$(verdict "$out")" "UNDECIDABLE"
ck_has  "silent registry is reported loudly"       "$out" "registry did not answer"

echo "── case 5: image inspect fails outright → LOUD, never swallowed"
out="$(CTR_REPODIGESTS="" IMG_INSPECT_FAILS=1 REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "failed image inspect is UNDECIDABLE"      "$(verdict "$out")" "UNDECIDABLE"
ck_has  "failed image inspect names the reason"    "$out" "could not be read"

echo "── case 6: the WRONG-OBJECT trap — a RepoDigests planted on the CONTAINER"
# Real Docker never puts RepoDigests on a container. This fixture does, holding
# the registry's CURRENT digest, while the IMAGE the container actually runs
# holds the STALE one. Reading the container object therefore yields "in-sync"
# and reading the image yields "DRIFT". Only the second is true: the container
# is running the stale image. This assertion is what makes the old selector
# structurally untestable-as-correct rather than merely unlucky.
out="$(CTR_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$REG_CURRENT\"]" \
       IMG_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$VM_STALE\"]" \
       REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "verdict follows the IMAGE, not the container"   "$(verdict "$out")" "DRIFT"

echo "── case 7: upstream images are not ours to judge"
out="$(CTR_REPODIGESTS="" IMG_REPODIGESTS="[]" REG_DIGESTS="" \
       OURS="postgres:16" run_status)"
ck     "upstream image reports n/a"               "$(verdict "$out")" "n/a"
ck_has  "upstream image does not fail the run"     "$out" "RC=0"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
