#!/usr/bin/env bash
# Test: step_docker installs an ERR trap that surfaces line + command + exit
# code on silent `set -e` failures.
#
# Without this, the parent's `wait $PID_DOCKER || log_error "docker build
# failed"` reports only the symptom — not the line that died. Surfaced
# 2026-04-27 (ship run 24995653483): step_docker died ~0.5s after
# "Native app packaged" with zero output between that and the parent's
# error message. Investigation cost ~30min that the trap would have
# eliminated.
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPT="$REPO_ROOT/1_configs/src/gha/scripts/cloud-ship-container-step-build-docker.sh"

[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

FAIL=0

# 1) The diagnostic helper function must exist.
if grep -qE '^[[:space:]]*_docker_err\(\)' "$SCRIPT"; then
    printf "  OK  _docker_err() helper defined\n"
else
    printf "  FAIL _docker_err() helper missing\n"
    FAIL=1
fi

# 2) ERR trap must be installed inside step_docker.
if grep -qE "trap '_docker_err .* ERR" "$SCRIPT"; then
    printf "  OK  ERR trap installed (calls _docker_err)\n"
else
    printf "  FAIL no ERR trap calling _docker_err — silent set -e exits stay silent\n"
    FAIL=1
fi

# 3) RETURN trap must clear ERR + RETURN on function exit (no leak into
#    parallel siblings step_configs_push / step_compose_build / step_secrets).
#
# Two acceptable forms:
#   (a) Inline:  trap 'trap - ERR RETURN' RETURN
#   (b) Helper:  trap '_docker_return_cleanup' RETURN  +  helper that runs
#               `trap - ERR RETURN` (used when extra cleanup, e.g. pipefail
#               restore for the SSH-builder branch, has to ride along).
if grep -qE "trap 'trap - ERR RETURN' RETURN" "$SCRIPT"; then
    printf "  OK  RETURN trap clears ERR + RETURN on function exit (inline)\n"
elif grep -qE "trap '_docker_return_cleanup' RETURN" "$SCRIPT" \
     && awk '/^[[:space:]]*_docker_return_cleanup\(\)/,/^[[:space:]]*\}/' "$SCRIPT" \
        | grep -qE 'trap - ERR RETURN'; then
    printf "  OK  RETURN trap clears ERR + RETURN on function exit (via _docker_return_cleanup helper)\n"
else
    printf "  FAIL no RETURN trap to clear — ERR could leak into other parallel steps\n"
    FAIL=1
fi

# 4) Diagnostic message must include line + exit code + the failing command.
if grep -qE 'step_docker died at line.*exit.*\$3' "$SCRIPT"; then
    printf "  OK  diagnostic message includes line + exit + BASH_COMMAND\n"
else
    printf "  FAIL diagnostic message does not include line/exit/command — debugging stays painful\n"
    FAIL=1
fi

# 5) The trap must be inside step_docker (not at file top — would leak into
#    every subsequent step the engine sources).
if awk '/^step_docker\(\) \{/,/^\}$/' "$SCRIPT" | grep -qE "trap '_docker_err .* ERR"; then
    printf "  OK  ERR trap declared inside step_docker (no leak into other steps)\n"
else
    printf "  FAIL ERR trap not scoped to step_docker — would leak into other steps\n"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::step_docker ERR trap regression"
    exit 1
fi

echo
echo "step_docker installs ERR + RETURN traps that surface silent set -e exits with line + command + code."
