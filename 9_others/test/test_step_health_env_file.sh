#!/usr/bin/env bash
# Tester (#760): step_health must read compose with the SAME interpolation
# source as the deploy (--env-file .secrets) whenever the service has secrets.
# Without it a `${VAR:?}` that only sops provides makes `compose ps` fail, and a
# healthy matomo deploy timed out as "No containers listed" (run 36958371453).
# Sources the REAL step; ssh is stubbed to record the remote commands.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-health.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASSES=0; FAILS=0
ok()  { PASSES=$((PASSES+1)); echo "  ok   $1"; }
bad() { FAILS=$((FAILS+1));  echo "  FAIL $1"; }

# run_health <dist-dir> — one probe round, every remote command into $TMP/cmds
run_health() {
    : > "$TMP/cmds"
    DIST_DIR="$1" DEPLOY_HOST=h DEPLOY_PATH=/opt/containers/x REMOTE_COMPOSE_REL=compose/docker-compose.yml \
    HEALTH_TIMEOUT=1 HEALTH_INTERVAL=1 CMDS="$TMP/cmds" bash -c '
        log() { :; }; log_error() { :; }
        . "$0"
        ssh_with_retry() { shift; printf "%s\n" "$*" >> "$CMDS"; }
        assert_declared_containers_live() { return 0; }
        step_health' "$STEP" >/dev/null 2>&1
}

mkdir -p "$TMP/with" "$TMP/without"; echo 'A=1' > "$TMP/with/.secrets"
run_health "$TMP/with"
grep -q 'docker compose --env-file .secrets -f compose/docker-compose.yml --project-directory . ps --format' "$TMP/cmds" \
    && ok "secrets present: compose ps gets --env-file .secrets" || { bad "secrets present: compose ps lacks --env-file"; sed 's/^/    /' "$TMP/cmds"; }
grep 'compose' "$TMP/cmds" | grep -qv -- '--env-file .secrets' \
    && bad "secrets present: some compose call still lacks --env-file" || ok "secrets present: every compose call carries it"
run_health "$TMP/without"
grep -q 'docker compose -f compose/docker-compose.yml --project-directory . ps' "$TMP/cmds" && ! grep -q -- '--env-file' "$TMP/cmds" \
    && ok "no secrets: no --env-file (a missing file would fail compose)" || { bad "no secrets: unexpected flags"; sed 's/^/    /' "$TMP/cmds"; }

echo "test_step_health_env_file: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
