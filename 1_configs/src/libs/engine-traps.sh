#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Shared library: standard engine error-surfacing                  ║
# ║                                                                  ║
# ║ Usage (from any cloud-ship-*-engine.sh / step-*.sh):             ║
# ║   . "$LIB_DIR/engine-traps.sh"                                   ║
# ║   engine_traps_install "step_docker"  # function name            ║
# ║   ...                                                            ║
# ║   engine_traps_clear                  # at function return       ║
# ║                                                                  ║
# ║ Or: pair with `trap '...' RETURN` to auto-clear on function exit.║
# ║                                                                  ║
# ║ What it does:                                                    ║
# ║   • set -eEo pipefail (strict mode + ERR-trap inheritance)       ║
# ║   • ERR trap: prints "<name> died at line N (exit X): <command>" ║
# ║   • Standard log/log_warn/log_error helpers (idempotent)         ║
# ║                                                                  ║
# ║ Why: today's 14-iteration outage (2026-04-27) had multiple       ║
# ║ silent set -e exits inside step_docker. Without an ERR trap, the ║
# ║ parent's `wait $PID || log "X failed"` reported only the symptom ║
# ║ — not the line. With this trap, every step file surfaces the     ║
# ║ exact line + command + exit code on first failure.               ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guard against double-sourcing.
[ "${_ENGINE_TRAPS_LOADED:-}" = "1" ] && return 0
_ENGINE_TRAPS_LOADED=1

# ── Logging helpers (only define if missing — don't clobber callers) ──
if ! command -v log >/dev/null 2>&1; then
    log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
fi
if ! command -v log_warn >/dev/null 2>&1; then
    log_warn() { printf "\033[0;33m[%s] WARNING: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1"; }
fi
if ! command -v log_error >/dev/null 2>&1; then
    log_error() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1" >&2; }
fi

# Internal: invoked by ERR trap.
_engine_traps_err() {
    _et_name="${1:-engine}"
    _et_line="${2:-?}"
    _et_rc="${3:-?}"
    _et_cmd="${4:-?}"
    log_error "$_et_name died at line $_et_line (exit $_et_rc): $_et_cmd"
    return "$_et_rc"
}

# Public: install ERR trap scoped to the current shell/function.
# Caller must clear with engine_traps_clear (or use RETURN trap).
#
# Args:
#   $1 — name shown in the diagnostic ("step_docker", "consolidate", …).
#        Defaults to a best-effort caller name.
engine_traps_install() {
    set -eEo pipefail
    _ETI_NAME="${1:-${FUNCNAME[1]:-engine}}"
    # shellcheck disable=SC2064  # we want $_ETI_NAME expanded NOW, $LINENO/$? at trap time
    trap "_engine_traps_err '$_ETI_NAME' \"\$LINENO\" \"\$?\" \"\$BASH_COMMAND\"" ERR
}

# Public: clear traps. Call at function return point or via RETURN trap.
engine_traps_clear() {
    trap - ERR RETURN
}

# Convenience: install + arrange auto-clear on RETURN.
# Call this as the FIRST line inside a function:
#     foo() {
#         engine_traps_scope "foo"
#         ...
#     }
engine_traps_scope() {
    set -eEo pipefail
    _ETS_NAME="${1:-${FUNCNAME[1]:-engine}}"
    # shellcheck disable=SC2064
    trap "_engine_traps_err '$_ETS_NAME' \"\$LINENO\" \"\$?\" \"\$BASH_COMMAND\"" ERR
    # shellcheck disable=SC2064
    trap "trap - ERR RETURN" RETURN
}
