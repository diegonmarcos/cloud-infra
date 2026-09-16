#!/usr/bin/env bash
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

# declared_container_names() comes from the ENGINE, not the step: the engine
# defines it before it sources any step file, and both steps that read a
# service's container list go through it (#20/L3 — the inline
# `jq '.containers[]?.container_name' 2>/dev/null` it replaced returned a
# SILENTLY TRUNCATED list on a malformed entry). It is lifted in verbatim
# rather than stubbed, so this harness exercises the same derivation
# production does; a stub here would let the step drift away from the engine
# without any test noticing.
ENGINE="$(dirname "$STEP")/cloud-ship-container-engine.sh"
[ -f "$ENGINE" ] || { echo "FAIL: $ENGINE missing"; exit 1; }
eval "$(sed -n '/^declared_container_names() {/,/^}/p' "$ENGINE")"
command -v declared_container_names >/dev/null 2>&1 \
  || { echo "FAIL: declared_container_names() not found in $ENGINE"; exit 1; }
# The engine provides this too; the function reports through it on the refusal
# path. Defined at top level so the run_status subshell inherits both.
log_error() { echo "ERROR: $*"; }

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
OURS_DEFAULT="$OURS"   # the ref case 8 expects the resolver to be asked about

mkdir -p "$WORK/dist" "$WORK/svc"
echo "dist-payload" > "$WORK/dist/file"
cat > "$WORK/svc/build.json" <<'JSON'
{ "containers": [ { "container_name": "cloud-cgc-pub-mcp" } ] }
JSON

# The injected desired-digest resolver. Emits REG_DIGESTS (empty = the
# registry would not answer) and logs the arguments it was handed.
cat > "$WORK/regdig" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${2:-}" >> "$REGDIG_CALLS"
[ -n "${REG_DIGESTS:-}" ] || exit 0
printf '%s\n' "$REG_DIGESTS"
STUB
chmod +x "$WORK/regdig"
REGDIG_CALLS="$WORK/regdig-calls"; export REGDIG_CALLS

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
          echo "$_cmd" >> "$WORK/img-inspect-calls"
          [ "${IMG_INSPECT_FAILS:-0}" = "1" ] && return 1
          printf '[{"Id":"%s","RepoDigests":%s}]' "$IMG_ID" "${IMG_REPODIGESTS:-[]}"
          ;;
        *) : ;;
      esac
    }

    # The registry seam (#358). The step no longer shells out to `docker
    # manifest inspect` / `docker buildx imagetools` itself — it asks
    # cloud-ship-registry-digest.sh, which owns the credential choice and is
    # shared with cloud-ship-reconcile.sh. So the seam that has to be injected
    # here is that script, not `docker`.
    #
    # The stub records every (ref, vm) pair it is called with, because the
    # whole point of #358 is WHICH credential answers: the digest must be
    # resolved against the VM that runs the container, not against whatever
    # docker login the caller happens to have. Case 8 asserts that.
    REGISTRY_DIGEST_CMD="$WORK/regdig"
    export REGISTRY_DIGEST_CMD

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

echo "── case 7: upstream images are not ours to judge, and are not probed for it"
: > "$WORK/img-inspect-calls"
out="$(CTR_REPODIGESTS="" IMG_REPODIGESTS="[]" REG_DIGESTS="" \
       OURS="postgres:16" run_status)"
ck     "upstream image reports n/a"               "$(verdict "$out")" "n/a"
ck_has  "upstream image does not fail the run"     "$out" "RC=0"
# The verdict alone does not prove this: an implementation that probes the image
# and then throws the answer away is equally "n/a". oci-apps declares 68
# containers, so a discarded round-trip per upstream container is dozens of
# pointless SSH connections into the fleet's deploy lock (#179). Assert the
# connection is never opened.
ck     "upstream image is never probed for a digest" \
       "$(wc -l < "$WORK/img-inspect-calls" | tr -d ' ')" "0"

echo "── case 7b: OUR images ARE probed on the image object (the round-trip happens)"
: > "$WORK/img-inspect-calls"
out="$(CTR_REPODIGESTS="" \
       IMG_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$REG_CURRENT\"]" \
       REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "our image is probed exactly once" \
       "$(wc -l < "$WORK/img-inspect-calls" | tr -d ' ')" "1"
ck_has  "and it is the IMAGE ID that is inspected, not the container name" \
       "$(cat "$WORK/img-inspect-calls")" "$IMG_ID"

echo "── case 8: the digest is resolved AGAINST THE VM, not against the caller"
# #358. Three of the fleet's packages are private (kg-store-binaries,
# session-memory-binaries, cf-worker-http-to-wg-public-bridge-binaries); ghcr
# issues no anonymous token for them and refuses this repo's GITHUB_TOKEN, so
# every sweep called them `undecidable` while all three were in fact in-sync.
# The credential that CAN read them is the one the VM already used to pull the
# image. That only holds if the VM is actually passed down to the resolver, so
# assert the argument rather than the outcome — an implementation that resolves
# against the operator's own docker login produces an identical verdict here
# and a wrong one on the fleet.
: > "$WORK/regdig-calls"
out="$(CTR_REPODIGESTS="" \
       IMG_REPODIGESTS="[\"ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries@$REG_CURRENT\"]" \
       REG_DIGESTS="$REG_CURRENT" run_status)"
ck     "the desired digest is asked for exactly once" \
       "$(wc -l < "$WORK/regdig-calls" | tr -d ' ')" "1"
ck     "and it is asked about the ref the container RUNS" \
       "$(cut -f1 "$WORK/regdig-calls")" "$OURS_DEFAULT"
ck     "and it is scoped to the VM that runs it (the pull credential lives there)" \
       "$(cut -f2 "$WORK/regdig-calls")" "testvm"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
