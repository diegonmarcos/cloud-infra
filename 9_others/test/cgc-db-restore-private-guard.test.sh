#!/usr/bin/env bash
# Guard test: CGC_INCLUDE_PRIVATE=1 must never write into the PUBLIC volume.
#
# The public/private split rests entirely on "the private repos' DBs are not in
# the volume the public MCP serves". That invariant used to be a comment in
# cloud-cgc-db-restore-all.sh; a comment does not stop the flag from being set on
# the public restore service. These cases pin the enforced version.
#
# Runs the real script with a stub `docker`/`jq` on PATH so nothing is pulled:
# every case here is expected to exit BEFORE the first pull.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/1_cicd/src/ops/cloud-cgc-db-restore-all.sh"
PASS=0; FAIL=0

STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
# Any pull attempt is a test failure: these cases must refuse before that point.
cat > "$STUB/docker" <<'STUBEOF'
#!/bin/sh
case "$1" in
  pull|create|cp|rm|run) echo "STUB-DOCKER-REACHED: $*" >&2; exit 42 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/docker"

check() { # name expect_rc expect_grep env...
  local name="$1" want_rc="$2" want="$3"; shift 3
  local out rc
  out=$(env PATH="$STUB:$PATH" "$@" sh "$SCRIPT" 2>&1); rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$want"; then
    PASS=$((PASS+1)); echo "  ok   $name"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $name (rc=$rc want=$want_rc)"
    printf '%s\n' "$out" | sed 's/^/         /' | head -8
  fi
}

echo "cgc-db-restore-all: CGC_INCLUDE_PRIVATE guard"

# The killer case: private data aimed straight at the public volume.
check "include-private + public target -> refuse" 1 "IS the public volume" \
  CGC_INCLUDE_PRIVATE=1 CGC_DB_TARGET_VOLUME=octocode_db \
  CGC_PUBLIC_DB_VOLUME=octocode_db CGC_INDEX_REPOS=cloud-data

# No explicit target = the script's default, which is the public one.
check "include-private + no target -> refuse" 1 "requires an explicit CGC_DB_TARGET_VOLUME" \
  CGC_INCLUDE_PRIVATE=1 CGC_PUBLIC_DB_VOLUME=octocode_db CGC_INDEX_REPOS=cloud-data

# Unverifiable target: fail closed, never guess. Run from a COPY outside the
# repo so build.json is genuinely unreachable -- which is the deployed shape
# (docker:cli writes this script to /tmp and has no checkout at all), not a
# contrived one. Every other env var is supplied so need_bj never fires either.
cp "$SCRIPT" "$STUB/restore-all.sh"
out=$(cd "$STUB" && env PATH="$STUB:$PATH" CGC_INCLUDE_PRIVATE=1 \
  CGC_DB_TARGET_VOLUME=octocode_db_pvt CGC_INDEX_REPOS=cloud-data \
  CGC_DB_TAG=latest CGC_DB_IMAGE_PREFIX=x/ CGC_DB_BASE_IMAGE=x/base:latest \
  HOME="$STUB" sh ./restore-all.sh 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "PUBLIC volume name is unknown"; then
  PASS=$((PASS+1)); echo "  ok   include-private + unknown public name -> refuse"
else
  FAIL=$((FAIL+1)); echo "  FAIL include-private + unknown public name -> refuse (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/         /' | head -8
fi

# The legitimate private restore proceeds (reaches the pull, i.e. past the guard).
check "include-private + private target -> proceed" 42 "private repos NOT filtered" \
  CGC_INCLUDE_PRIVATE=1 CGC_DB_TARGET_VOLUME=octocode_db_pvt \
  CGC_PUBLIC_DB_VOLUME=octocode_db CGC_INDEX_REPOS=cloud-data

# And the public path is untouched by all of the above: still filters.
check "public restore still filters private repos" 1 "every requested repo is private" \
  CGC_DB_TARGET_VOLUME=octocode_db CGC_PRIVATE_REPOS=cloud-data CGC_INDEX_REPOS=cloud-data

echo "  ---- $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
