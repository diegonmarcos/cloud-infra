#!/bin/sh
# test_ship_configs_push_failure.sh — the configs-image step must not claim
# success for a push it did not make.
#
# `docker push ... | tail -3` reported tail's exit code, so a GHCR
# "denied: permission_denied: write_package" logged "Pushed configs image" and
# recorded .configs-hash. That hash is what the NEXT run compares against to
# decide whether to rebuild, so one denied push made the failure permanent:
# every later run saw an unchanged hash, skipped the push entirely, and kept
# deploying stale configs. caddy sat stale that way.
#
# Everything here runs against a stub `docker` on PATH — no daemon, no network,
# no registry.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-build-configs.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
nope() { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (expected '$3', got '$2')"; fi; }

[ -f "$STEP" ] || { echo "FAIL: $STEP missing"; exit 1; }

# Build a fixture: a service dir with a dist/ holding a REAL .dockerignore we
# can prove is still there afterwards.
setup() {
  WORK=$(mktemp -d)
  SERVICE_DIR="$WORK/svc"
  DIST_DIR="$SERVICE_DIR/dist"
  mkdir -p "$DIST_DIR" "$WORK/bin"
  echo "ORIGINAL-DOCKERIGNORE" > "$DIST_DIR/.dockerignore"
  echo "cfg" > "$DIST_DIR/config.yaml"
  printf 'services:\n  app:\n    image: x\n' > "$WORK/compose.yaml"

  # Stub docker. `push` obeys $STUB_PUSH_RC, everything else succeeds.
  cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
  push) echo "denied: permission_denied: write_package" >&2; exit ${STUB_PUSH_RC:-0} ;;
  *)    exit 0 ;;
esac
STUB
  chmod +x "$WORK/bin/docker"
  PATH="$WORK/bin:$PATH"; export PATH
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# Run the step function in a subshell with the env it expects.
run_step() {
  ( . "$STEP" 2>/dev/null
    log()      { :; }
    log_warn() { :; }
    DIST_DIR="$DIST_DIR"; SERVICE_DIR="$SERVICE_DIR"
    SERVICE_NAME="testsvc"; DOCKER_ARCH="arm64"
    COMPOSE_FILE="$WORK/compose.yaml"
    DOCKER_REGISTRY="ghcr.io/example"
    GITHUB_TOKEN=""; GITHUB_ACTOR="tester"
    export DIST_DIR SERVICE_DIR SERVICE_NAME DOCKER_ARCH COMPOSE_FILE DOCKER_REGISTRY
    fn=$(grep -oE '^[a-z_]+\(\)' "$STEP" | head -1 | tr -d '()')
    [ -n "$fn" ] || exit 97
    "$fn" >/dev/null 2>&1
    echo "rc=$?"
  )
}

echo "== push denied =="
setup
STUB_PUSH_RC=1 export STUB_PUSH_RC
out=$(run_step)
case "$out" in *rc=97*) echo "  SKIP: could not locate step function"; teardown; exit 0 ;; esac

# The whole point: a denied push must not be recorded as done.
if [ -f "$SERVICE_DIR/.configs-hash" ]; then
  nope "denied push must NOT record .configs-hash (it would make the failure sticky)"
else
  ok "denied push does not record .configs-hash"
fi
check "dist/.dockerignore restored after failed push" \
  "$(cat "$DIST_DIR/.dockerignore" 2>/dev/null)" "ORIGINAL-DOCKERIGNORE"
[ -f "$DIST_DIR/.dockerignore.bak" ] && nope "stale .dockerignore.bak left behind" \
                                     || ok "no stale .dockerignore.bak"
[ -f "$DIST_DIR/Dockerfile.configs" ] && nope "stale Dockerfile.configs left behind" \
                                      || ok "no stale Dockerfile.configs"
check "step stays non-fatal on push failure" "$out" "rc=0"
teardown

echo "== push succeeds =="
setup
STUB_PUSH_RC=0 export STUB_PUSH_RC
out=$(run_step)
if [ -f "$SERVICE_DIR/.configs-hash" ]; then
  ok "successful push records .configs-hash"
else
  nope "successful push must record .configs-hash"
fi
check "dist/.dockerignore restored after successful push" \
  "$(cat "$DIST_DIR/.dockerignore" 2>/dev/null)" "ORIGINAL-DOCKERIGNORE"
check "step succeeds" "$out" "rc=0"
teardown

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass assertions)"; exit 0; fi
echo "FAIL ($fail of $((pass+fail)))"
exit 1
