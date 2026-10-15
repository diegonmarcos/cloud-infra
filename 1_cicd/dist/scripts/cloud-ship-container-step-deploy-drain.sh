# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloud-ship-container-step-deploy-drain.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step helper: run the compose payload on the VM — through the agent drain when the service's
# build.json declares deploy.drain. Sourced by cloud-ship-container-engine.sh; step_compose
# calls compose_run where it used to call ssh_run_detached directly.
#
# The payload's `down` + `rm -f` kill every process in the container. For an agent container
# that means every agent mid-task: cloud-agi-claude was recreated by three ordinary ships on
# 2026-10-01 and the last took six agents with it. deploy.drain names a probe (live.sh in
# cloud-u-containers/_dispatch/) that lists the live agents; this helper asks it first, and
#   none live -> recreates now, in this job, exactly as before (through the waiter, so the
#                admission hold and the newest-ship-wins ownership still apply);
#   some live -> hands the recreate to cloud-ship-container-drain-waiter.sh, detached ON THE
#                VM, names the agents in this log, and returns 0. The old container keeps
#                serving; the new config is already rsynced and waits for the waiter.
# Waiting here instead was rejected on evidence: ship.yml's deploy job is capped at 90 minutes
# and holds the fleet-wide ship-wg-runner slot, so an hours-long wait would stall every deploy
# in the fleet and then time out anyway.
#
# SHIP_DRAIN_FORCE=1 skips the drain and recreates over live agents (operator override).
# Every failure to establish the agent count fails the step — a drain that cannot see agents
# must not read as a drain that found none.

# compose_run <payload> <label> <declared container names>
compose_run() {
    _cr_probe="$(get_config deploy.drain.probe)"
    if [ -z "$_cr_probe" ]; then
        ssh_run_detached "$DEPLOY_HOST" "$1" "$2"; return $?
    fi
    if [ -n "${SHIP_DRAIN_FORCE:-}" ]; then
        log_warn "DRAIN OVERRIDDEN (SHIP_DRAIN_FORCE) — recreating $3 without waiting for live agents"
        ssh_run_detached "$DEPLOY_HOST" "$1" "$2"; return $?
    fi
    _cr_max="$(get_config deploy.drain.max_wait_seconds)"
    _cr_poll="$(get_config deploy.drain.poll_seconds)"
    _cr_user="$(get_config deploy.drain.exec_user)"
    case "$_cr_max$_cr_poll" in ''|*[!0-9]*) log_error "deploy.drain: max_wait_seconds and poll_seconds must be integers (got '$_cr_max' '$_cr_poll')"; return 1 ;; esac
    [ -n "$_cr_user" ] || { log_error "deploy.drain.exec_user is required (the uid that owns the dispatch tree)"; return 1; }
    [ -s "$SERVICE_DIR/$_cr_probe" ] || { log_error "deploy.drain.probe not found: $SERVICE_DIR/$_cr_probe — refusing to recreate blind"; return 1; }
    [ -n "$3" ] || { log_error "deploy.drain: no declared containers to probe"; return 1; }
    [ -z "$COMPOSE_POST_HOOK" ] || { log_error "deploy.drain with compose.post_hook is unsupported: a deferred recreate would leave the hook unrun"; return 1; }

    _cr_dir="$DEPLOY_PATH/.drain"
    _cr_args="$_cr_max $_cr_poll $_cr_user $3"
    # Staged by value in the command line, not over stdin: ssh_with_retry re-runs a dropped
    # command, and a retried stdin upload writes an EMPTY file — an empty probe reads as "no
    # agents". tmp + mv so a waiter mid-read keeps its own inode.
    _cr_put() { # _cr_put <name> <local file>
        ssh_with_retry "$DEPLOY_HOST" "mkdir -p '$_cr_dir' && printf '%s' '$(base64 -w0 < "$2")' | base64 -d > '$_cr_dir/$1.tmp' && mv '$_cr_dir/$1.tmp' '$_cr_dir/$1'"
    }
    _cr_cmd="$(mktemp)"
    printf '%s\n' "$1" > "$_cr_cmd"
    _cr_put waiter.sh "$STEPS_DIR/cloud-ship-container-drain-waiter.sh" \
        && _cr_put probe.sh "$SERVICE_DIR/$_cr_probe" \
        && _cr_put cmd.sh "$_cr_cmd" \
        || { rm -f "$_cr_cmd"; log_error "drain: staging $_cr_dir on $DEPLOY_HOST failed"; return 1; }
    rm -f "$_cr_cmd"

    _cr_prev="$(ssh $SSH_OPTS "$DEPLOY_HOST" "tail -n 2 '$_cr_dir/waiter.log' 2>/dev/null" 2>/dev/null || true)"
    [ -z "$_cr_prev" ] || log "drain: last deferred-recreate log lines on $DEPLOY_HOST: $(printf '%s' "$_cr_prev" | tr '\n' '|')"

    _cr_live="$(ssh_with_retry "$DEPLOY_HOST" "bash '$_cr_dir/waiter.sh' check $_cr_args")" \
        || { log_error "drain: live-agent check failed on $DEPLOY_HOST — refusing to recreate blind"; return 1; }
    if [ -z "$_cr_live" ]; then
        log "drain: no live agent in $3 — recreating now"
        ssh_run_detached "$DEPLOY_HOST" "bash '$_cr_dir/waiter.sh' run $_cr_args" "$2"; return $?
    fi

    log_warn "════ DRAIN: $(printf '%s\n' "$_cr_live" | grep -c .) live agent(s) in $3 — recreate DEFERRED, NOT run now ════"
    printf '%s\n' "$_cr_live" | while IFS= read -r _cr_l; do log_warn "  live: $_cr_l"; done
    _cr_pid="$(ssh_with_retry "$DEPLOY_HOST" "bash '$_cr_dir/waiter.sh' launch $_cr_args")" \
        || { log_error "drain: could not launch the waiter on $DEPLOY_HOST — nothing recreated"; return 1; }
    log_warn "drain: waiter pid $_cr_pid on $DEPLOY_HOST recreates once they finish (max ${_cr_max}s); new fires are refused meanwhile. Log: $DEPLOY_HOST:$_cr_dir/waiter.log"
}
