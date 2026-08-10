#!/usr/bin/env bash
# Test: step_docker GHCR login is best-effort — tolerates failure (|| true)
# and preserves stderr for debuggability.
#
# Original failure mode 2026-04-27 (ship run 24998359368, surfaced by ERR
# trap from run 24998359368/Phase 26): inside cloud-builder, the host's
# ${HOME}/.docker/config.json is bind-mounted RO. `docker login` tried to
# write back → exit 1. `2>/dev/null` swallowed the error. set -e aborted
# step_docker silently. ERR trap surfaced "step_docker died at line 212".
#
# Fix locks in two properties of the engine:
#   1. The login is wrapped with `|| true` so a redundant-login failure
#      doesn't abort step_docker. The host already logged in pre-compose.
#   2. Stderr is NOT suppressed wholesale; only known-noise lines are
#      filtered. Real errors stay visible for the next debugger.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/1_configs/src/scripts/cloud-ship-container-step-build-docker.sh"

[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

FAIL=0

# 1) docker login lines must NOT have a bare `2>/dev/null` (suppresses errors).
BARE_REDIRECT=$(grep -nE 'docker login ghcr\.io.*2>/dev/null$' "$SCRIPT" || true)
if [ -n "$BARE_REDIRECT" ]; then
    printf "  FAIL bare 2>/dev/null on docker login (silences real errors):\n%s\n" "$BARE_REDIRECT"
    FAIL=1
else
    printf "  OK  no bare 2>/dev/null suppressing docker login errors\n"
fi

# 2) Each docker login pipeline must be terminated with `|| true` so a
#    redundant-login failure doesn't abort step_docker via set -e.
LOGIN_LINES=$(grep -nE 'docker login ghcr\.io' "$SCRIPT" || true)
LOGIN_COUNT=$(printf '%s\n' "$LOGIN_LINES" | grep -cE 'docker login ghcr\.io' || true)
TOLERANT_COUNT=$(awk '/docker login ghcr\.io/,/^$/' "$SCRIPT" | grep -cE '\|\|[[:space:]]*true' || true)
if [ "$LOGIN_COUNT" -ge 2 ] && [ "$TOLERANT_COUNT" -ge 2 ]; then
    printf "  OK  docker login pipelines tolerate failure (%d || true matches for %d login lines)\n" "$TOLERANT_COUNT" "$LOGIN_COUNT"
else
    printf "  FAIL docker login pipelines do not tolerate failure — set -e will abort step_docker on RO config.json\n"
    printf "      login lines: %d, || true matches: %d\n" "$LOGIN_COUNT" "$TOLERANT_COUNT"
    FAIL=1
fi

# 3) The known-noise filter must include the credential-helper warning so
#    log output stays readable when login succeeds.
if grep -qE 'credential helper' "$SCRIPT"; then
    printf "  OK  noise filter excludes the credential-helper warning\n"
else
    printf "  FAIL no filter for the credential-helper warning — every successful login spams 3 lines\n"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::step_docker GHCR login tolerance regression"
    exit 1
fi

echo
echo "step_docker GHCR login is best-effort: failures don't abort, errors stay visible, noise is filtered."
