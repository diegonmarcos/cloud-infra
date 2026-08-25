#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/ghcr-artifacts-compose-rewrite.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Regression test for rewrite_compose_image_refs (PLAN-ghcr-artifacts.md item 3).
#
# compose.nix bakes each service's image ref as a literal Nix-interpolated
# string AT BUILD TIME (`binariesImage = ".../${name}-binaries:latest";
# image = binariesImage;`) — there is no runtime templating, so a
# reproducible deploy pointer (digest or git-sha12, known only AFTER
# step_docker pushes) has to be a post-render text rewrite of the already-
# generated docker-compose.yml, not a Nix change. This test EXTRACTS the real
# function from cloud-ship-container-engine.sh and EXECUTES it against a
# throwaway compose file for all three fallback tiers plus the malformed-
# input case — a grep for the sed idiom would not catch a future rewrite
# that gets the tier order, the delimiter, or the -binaries/plain-image
# split wrong.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="$ROOT/1_cicd/src/scripts/cloud-ship-container-engine.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# Extract the function body verbatim (top-level, 0-indent in the source).
awk '
  /^rewrite_compose_image_refs\(\) \{/ { f=1 }
  f { print }
  f && /^\}$/ { exit }
' "$ENGINE" > "$T/fn.sh"
ck "function extracted from engine" "$(grep -c 'rewrite_compose_image_refs() {' "$T/fn.sh")" "1"

mkcompose() { # (re)writes a throwaway compose file with both ref styles,
              # plus an unrelated service's image that must never be touched.
  cat > "$T/compose.yml" <<COMPOSEEOF
services:
  svc:
    image: ghcr.io/diegonmarcos/example-svc-binaries:latest
  other:
    image: ghcr.io/diegonmarcos/example-svc:latest
  unrelated:
    image: ghcr.io/diegonmarcos/some-other-svc-binaries:latest
COMPOSEEOF
}

run_case() { # $1=DEPLOY_IMAGE_DIGEST  $2=DEPLOY_IMAGE_SHA12 -> prints resulting compose.yml
  mkcompose
  (
    log() { :; }; log_warn() { :; }
    COMPOSE_FILE="$T/compose.yml"
    DOCKER_REGISTRY="ghcr.io/diegonmarcos"
    DOCKER_IMAGE="example-svc"
    DEPLOY_IMAGE_DIGEST="$1"
    DEPLOY_IMAGE_SHA12="$2"
    . "$T/fn.sh"
    rewrite_compose_image_refs
  )
  cat "$T/compose.yml"
}

FAKE_DIGEST="sha256:$(printf '%064d' 1)"

# ── Tier 3: neither set -> unchanged (today's exact behaviour; this is what
#    keeps items 1+3+7 behaviour-neutral until items 2/4 wire a caller). ──
OUT=$(run_case "" "")
ck "tier3: binaries :latest unchanged"        "$(printf '%s\n' "$OUT" | grep -c 'example-svc-binaries:latest')" "1"
ck "tier3: plain :latest unchanged"           "$(printf '%s\n' "$OUT" | grep -c 'image: ghcr.io/diegonmarcos/example-svc:latest')" "1"
ck "tier3: unrelated service's :latest untouched" "$(printf '%s\n' "$OUT" | grep -c 'some-other-svc-binaries:latest')" "1"

# ── Tier 2: DEPLOY_IMAGE_SHA12 -> :<sha12> ──
OUT=$(run_case "" "abc123456789")
ck "tier2: binaries rewritten to :sha12" "$(printf '%s\n' "$OUT" | grep -c 'example-svc-binaries:abc123456789')" "1"
ck "tier2: plain rewritten to :sha12"    "$(printf '%s\n' "$OUT" | grep -c 'image: ghcr.io/diegonmarcos/example-svc:abc123456789')" "1"
ck "tier2: unrelated service's :latest untouched" "$(printf '%s\n' "$OUT" | grep -c 'some-other-svc-binaries:latest')" "1"
ck "tier2: no :latest left for this service" "$(printf '%s\n' "$OUT" | grep -cE 'example-svc(-binaries)?:latest')" "0"

# ── Tier 1: DEPLOY_IMAGE_DIGEST -> @sha256:<digest> (wins even if sha12 also set) ──
OUT=$(run_case "$FAKE_DIGEST" "abc123456789")
ck "tier1: digest wins over sha12 when both set" "$(printf '%s\n' "$OUT" | grep -c "example-svc-binaries@${FAKE_DIGEST}")" "1"
ck "tier1: plain image also gets @digest"        "$(printf '%s\n' "$OUT" | grep -c "image: ghcr.io/diegonmarcos/example-svc@${FAKE_DIGEST}")" "1"
ck "tier1: unrelated service's :latest untouched" "$(printf '%s\n' "$OUT" | grep -c 'some-other-svc-binaries:latest')" "1"
ck "tier1: no leftover :tag riding along with @digest" "$(printf '%s\n' "$OUT" | grep -cE ':[a-zA-Z0-9]+@sha256')" "0"

# ── Malformed digest (not sha256:<hex>) is rejected, not silently mismatched ──
OUT=$(run_case "notadigest" "")
ck "malformed digest ignored -> :latest unchanged" "$(printf '%s\n' "$OUT" | grep -c 'example-svc-binaries:latest')" "1"

# ── No COMPOSE_FILE at all -> no-op, not an error (e.g. a verb that skips step_build) ──
(
  log() { :; }; log_warn() { :; }
  COMPOSE_FILE="$T/does-not-exist.yml"
  DOCKER_REGISTRY="ghcr.io/diegonmarcos"; DOCKER_IMAGE="example-svc"
  DEPLOY_IMAGE_DIGEST="$FAKE_DIGEST"; DEPLOY_IMAGE_SHA12=""
  . "$T/fn.sh"
  rewrite_compose_image_refs
)
ck "missing COMPOSE_FILE is a clean no-op" "$?" "0"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
