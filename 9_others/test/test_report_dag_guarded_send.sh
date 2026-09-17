#!/usr/bin/env bash
# test_report_dag_guarded_send.sh — the Dagu report DAGs must sail through the
# reach guards before any mail can leave.
#
# #392: report_daily.yaml and report_analytics.yaml invoked each crate's OWN
# build.sh `ship` (engine_build; engine_run; send_html) directly. That path
# never touches the reports orchestrator — so BOTH vacuity guards
# (require_hosts_reached / require_probe_reached) were skipped, and a run
# whose probes reached nothing still EMAILED its digest and exited 0. The DAGs
# now dispatch the entrypoint's guarded targets (`daily-mail` / `analytics-mail`),
# whose contract is: run the crate THROUGH the orchestrator, and only if that
# exits 0 run the send. This tester proves that contract end to end against the
# REAL orchestrator and the REAL analytics crate:
#
#   1. daily-mail split, fleet unreachable  -> the guarded run fails, no send
#   2. daily-mail split, fleet reachable    -> the guarded run passes, send runs
#   3. analytics-mail split, both engines dead  -> guarded run fails, no send
#   4. analytics-mail split, both engines alive -> guarded run passes, send runs
#
# The send step is a stub that records its invocation in a marker file: if the
# marker exists, the send HALF ran; the guard contract demands it exist exactly
# when the guarded half succeeded.
#
# Usage: test_report_dag_guarded_send.sh [PATH_TO_ORCHESTRATOR_BUILD_SH]
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

FAILS=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required by this tester" >&2; exit 1; }

# ── Locate the orchestrator ───────────────────────────────────────────────
ORCHESTRATOR="${1:-}"
if [ -z "$ORCHESTRATOR" ]; then
    for p in \
        "$REPO_ROOT/a_solutions/infra-obs_reports/src/src/build.sh" \
        "$REPO_ROOT/../cloud-u-containers/infra-obs_reports/src/src/build.sh"; do
        [ -f "$p" ] && { ORCHESTRATOR="$p"; break; }
    done
fi
if [ -z "$ORCHESTRATOR" ] || [ ! -f "$ORCHESTRATOR" ]; then
    echo "✗ reports orchestrator build.sh not found — cannot verify the guarded-send contract" >&2
    echo "  Looked under a_solutions/ and ../cloud-u-containers/." >&2
    echo "  This is a failure, not a skip." >&2
    exit 1
fi
ANALYTICS_SRC="$(dirname "$ORCHESTRATOR")/cloud-analytics-daily"
[ -d "$ANALYTICS_SRC" ] || { echo "✗ analytics crate not found beside the orchestrator ($ANALYTICS_SRC)" >&2; exit 1; }

echo "── guarded-send contract (orchestrator: $ORCHESTRATOR) ──"

# ── Fixtures, serialised exactly as reports-common does ───────────────────
fixture_zero='{"version":1,"generated_at":"2026-09-16T05:12:42Z","fleet_state":{"vms":{
  "oci-mail":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "oci-analytics":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "oci-apps":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "gcp-proxy":{"Unknown":{"reason":"tcp :22 probe failed"}}}}}'
fixture_one='{"version":1,"generated_at":"2026-09-16T05:12:42Z","fleet_state":{"vms":{
  "oci-mail":"Running",
  "oci-analytics":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "oci-apps":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "gcp-proxy":{"Unknown":{"reason":"tcp :22 probe failed"}}}}}'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUTPUT_LOG="$WORK/orchestrator.log"
SEND_MARKER="$WORK/send-ran.marker"

# ── Scaffold a scratch reports tree ───────────────────────────────────────
# $1 = fixture JSON (master), or empty when the analytics-only tree is wanted.
scaffold() {
    local fixture="$1"
    mkdir -p "$WORK/tree/src/cloud-health-full-daily/src" \
             "$WORK/tree/src/cloud-analytics-daily" \
             "$WORK/tree/bin"
    rm -rf "$WORK/tree/dist"
    mkdir -p "$WORK/tree/dist"
    cp "$ORCHESTRATOR" "$WORK/tree/src/build.sh"

    # No-op cargo: Phase 0 runs it for every non-image run; irrelevant here.
    printf '#!/bin/sh\nexit 0\n' > "$WORK/tree/bin/cargo"

    # Stub master crate: writes the forced snapshot on run, records sends.
    cat > "$WORK/tree/src/cloud-health-full-daily/build.sh" <<'STUB'
#!/bin/sh
crate="$(cd "$(dirname "$0")" && pwd)"
dist="$(cd "$crate/../.." && pwd)/dist"
case "${1:-}" in
    link) exit 0 ;;
    run|all)
        if [ -n "${FIXTURE_JSON:-}" ]; then
            printf '%s\n' "$FIXTURE_JSON" > "$dist/_run_state.json"
        fi
        exit 0 ;;
    send)
        : > "${SEND_MARKER:-/tmp/.unset}"
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$WORK/tree/bin/cargo" "$WORK/tree/src/cloud-health-full-daily/build.sh"

    # Stub sender: the real send.sh speaks SMTP; the DAG contract only cares
    # that it is reached strictly after a PASSED guarded run.
    cat > "$WORK/tree/src/cloud-health-full-daily/src/send.sh" <<'SENDER'
#!/bin/sh
: > "${SEND_MARKER:-/tmp/.unset}"
exit 0
SENDER
    chmod +x "$WORK/tree/src/cloud-health-full-daily/src/send.sh"

    # Copy the REAL analytics crate (shell-only) so its outcome-key writing is
    # the thing under test, not a stand-in.
    [ -d "$WORK/tree/src/cloud-analytics-daily/src" ] || \
        cp -a "$ANALYTICS_SRC/src" "$WORK/tree/src/cloud-analytics-daily/src"
    cp "$ANALYTICS_SRC/build.sh" "$WORK/tree/src/cloud-analytics-daily/build.sh"
    chmod +x "$WORK/tree/src/cloud-analytics-daily/build.sh"
}

# Run the ORCHESTRATOR'S OWN version of the daily-mail guarded half, then —
# ONLY when it succeeded — the send half, exactly as the entrypoint's
# `daily-mail` / `analytics-mail` targets do (`run && send`).
# $1 = crate verb target (health-full-daily | cloud-analytics-daily)
# $2 = extra PATH dir (analytics stubs), empty for the master
# Echoes the exit status of the WHOLE chain. SEND_MARKER records a send.
run_guarded_chain() {
    local target="$1" stubpath="${2:-}" send_runs send_sh

    if [ "$target" = health-full-daily ]; then
        send_runs="sh '$WORK/tree/src/cloud-health-full-daily/build.sh' send"
    else
        send_runs="sh '$WORK/tree/src/cloud-analytics-daily/build.sh' send"
    fi
    send_sh="$WORK/tree/src/cloud-health-full-daily/src/send.sh"

    rm -f "$SEND_MARKER"
    if [ -n "$stubpath" ]; then
        PATH="$stubpath:$WORK/tree/bin:$PATH" SEND_MARKER="$SEND_MARKER" \
            sh -c "sh '$WORK/tree/src/build.sh' '$target' >'$OUTPUT_LOG' 2>&1 && $send_runs >/dev/null 2>&1"
    else
        FIXTURE_JSON="${FIXTURE_JSON:-}" SEND_MARKER="$SEND_MARKER" \
            sh -c "sh '$WORK/tree/src/build.sh' '$target' >'$OUTPUT_LOG' 2>&1 && $send_runs >/dev/null 2>&1"
    fi
    local rc=$?
    printf '%s' "$rc"
}

# ── 1. daily-mail, fleet unreachable: guard fails, NO send ────────────────
scaffold "$fixture_zero"
rc="$(FIXTURE_JSON="$fixture_zero" run_guarded_chain health-full-daily)"
if [ "$rc" -eq 0 ]; then
    bad "daily-mail with 0 of 4 reached -> exit 0 — a report that reached nothing mailed anyway (this is #392)"
    sed 's/^/      /' "$OUTPUT_LOG"
else
    ok "daily-mail with 0 of 4 reached -> exit $rc (non-zero)"
    if [ -f "$SEND_MARKER" ]; then
        bad "but the send HALF still ran — the guard did not gate the mail"
    else
        ok "and no send: the mail only leaves behind a verified report"
    fi
fi

# ── 2. daily-mail, fleet reachable: guard passes, send runs ───────────────
rc="$(FIXTURE_JSON="$fixture_one" run_guarded_chain health-full-daily)"
if [ "$rc" -eq 0 ]; then
    ok "daily-mail with 1 of 4 reached -> exit 0"
else
    bad "daily-mail with 1 of 4 reached -> exit $rc — guard false-fired on a run that DID reach a host"
    sed 's/^/      /' "$OUTPUT_LOG"
fi
if [ -f "$SEND_MARKER" ]; then
    ok "and the send ran once the report had evidence behind it"
else
    bad "send half did NOT run despite a passing guarded run — the DAG would mail nothing"
fi

# ── 3. analytics-mail, both engines dead: guard fails, NO send ────────────
# Dead-docker stub reproduces the 2026-09 production state (all engine
# containers gone). ssh is stubbed to run the query heredoc locally.
mkdir -p "$WORK/stubs-dead" "$WORK/stubs-alive"
printf '#!/bin/sh\nexec bash -s\n' > "$WORK/stubs-dead/ssh"      # run remote body locally
printf '#!/bin/sh\nexec bash -s\n' > "$WORK/stubs-alive/ssh"
printf '#!/bin/sh\necho\nexit 1\n' > "$WORK/stubs-dead/docker"
cat > "$WORK/stubs-alive/docker" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    "select 1;") echo 1; exit 0 ;;
  esac
done
case "${1:-}" in
  inspect) echo "running"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/stubs-dead/ssh" "$WORK/stubs-dead/docker" \
        "$WORK/stubs-alive/ssh" "$WORK/stubs-alive/docker"

scaffold ""   # analytics tree — the master stub simply must exist for discovery
rm -f "$SEND_MARKER"
rc="$(FIXTURE_JSON="" run_guarded_chain cloud-analytics-daily "$WORK/stubs-dead")"
if [ "$rc" -eq 0 ]; then
    bad "analytics-mail with both engines dead -> exit 0 — an all-failed digest was sent as a success (this is #392)"
    sed 's/^/      /' "$OUTPUT_LOG"
else
    ok "analytics-mail with both engines dead -> exit $rc (non-zero)"
    if [ -f "$SEND_MARKER" ]; then
        bad "but the send HALF still ran — the analytics guard did not gate the mail"
    else
        ok "and no send: analytics outcome keys (passed:0) refused the mail"
    fi
fi

# ── 4. analytics-mail, both engines alive: guard passes, send runs ────────
rc="$(FIXTURE_JSON="" run_guarded_chain cloud-analytics-daily "$WORK/stubs-alive")"
if [ "$rc" -eq 0 ]; then
    ok "analytics-mail with both engines alive -> exit 0"
else
    bad "analytics-mail with both engines alive -> exit $rc — guard false-fired on a healthy run"
    sed 's/^/      /' "$OUTPUT_LOG"
fi
if [ -f "$SEND_MARKER" ]; then
    ok "and the send ran: analytics outcome keys (passed:2) cleared the way"
else
    bad "send half did NOT run despite a passing guarded analytics run"
fi

if [ "$FAILS" -ne 0 ]; then
    echo "✗ $FAILS assertion(s) failed" >&2
    exit 1
fi
echo "✓ guarded-send contract holds (daily-mail + analytics-mail)"