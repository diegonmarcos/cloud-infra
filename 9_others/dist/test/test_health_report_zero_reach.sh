#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_health_report_zero_reach.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_health_report_zero_reach.sh — a health report that reached 0 hosts must
# exit non-zero.
#
# THE FAILURE THIS GUARDS (#374)
#   cloud-health-reports-arm-oci-apps.yml concluded `success` on eight
#   consecutive runs, 2026-09-01 through 2026-09-16, while reaching none of the
#   four VMs it claims to probe. Its GitHub-hosted runner had no route to the
#   WireGuard mesh, so every SSH to a 10.0.0.0/24 address failed. The newest of
#   those runs, 35058414004 (job 104673352667), says so in its own log:
#       Fleet: 0/4 reachable
#       SSH oci-mail UNREACHABLE: SSH failed   (and oci-analytics, oci-apps,
#       L2 WG Mesh: 0/4 reachable in 6.0s       gcp-proxy)
#   and then exited 0. Nothing in the pipeline asserted the reach count was
#   above zero, so eight empty probes were published as eight clean bills of
#   health and consumed downstream as evidence the fleet was fine.
#
# WHAT THIS ASSERTS — BEHAVIOUR, NOT SOURCE TEXT
#   The reports orchestrator (cloud-u-containers
#   infra-obs_reports/src/src/build.sh) is driven for real, end to end, with a
#   stubbed master crate standing in for the Rust binary. The stub writes a
#   forced _run_state.json and exits 0 exactly as the real binary did on the
#   ARM runner. The verdict is the orchestrator's own exit status.
#
#   1. zero reach       -> `build.sh all` must exit NON-ZERO
#   2. one host reached -> `build.sh all` must exit ZERO   (no false positives:
#                          a guard that always fails proves nothing either)
#   3. no snapshot      -> `build.sh all` must exit NON-ZERO (a run that
#                          recorded no fleet state also verified nothing)
#   4. :22 answers everywhere but no host returned SSH data -> NON-ZERO.
#                          TCP reach is not collection (#391).
#
#   Passing an alternative orchestrator as $1 is how the fix was mutation-
#   proved in both directions: point it at a PRE-FIX checkout of build.sh and
#   case 1 must go GREEN, which is what shows the guard — and not some other
#   change — is what turns the zero-reach run red.
#
# Usage: test_health_report_zero_reach.sh [PATH_TO_ORCHESTRATOR_BUILD_SH]
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

FAILS=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

# ── Locate the orchestrator ───────────────────────────────────────────────
# Not finding it is a FAILURE, never a skip. A tester that cannot reach its
# subject and exits 0 is the same defect this whole ticket is about.
ORCHESTRATOR="${1:-}"
if [ -z "$ORCHESTRATOR" ]; then
    for p in \
        "$REPO_ROOT/a_solutions/infra-obs_reports/src/src/build.sh" \
        "$REPO_ROOT/../cloud-u-containers/infra-obs_reports/src/src/build.sh"; do
        [ -f "$p" ] && { ORCHESTRATOR="$p"; break; }
    done
fi
if [ -z "$ORCHESTRATOR" ] || [ ! -f "$ORCHESTRATOR" ]; then
    echo "✗ reports orchestrator build.sh not found — cannot verify the reach guard" >&2
    echo "  Looked under a_solutions/ and ../cloud-u-containers/." >&2
    echo "  This is a failure, not a skip: an unverifiable guard is an absent one." >&2
    exit 1
fi
echo "── zero-reach guard (orchestrator: $ORCHESTRATOR) ──"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required by this tester" >&2; exit 1; }

# ── Fixtures: fleet_state exactly as reports-common serialises it ──────────
# Unit variants render as bare strings; Client as {"Client":{"tcp_up":bool}}.
# The zero-reach fixture is the shape the ARM runner actually produced: four
# declared VMs, none of them classified reachable.
fixture_zero='{"version":1,"generated_at":"2026-09-16T05:12:42Z","fleet_state":{"vms":{
  "oci-mail":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "oci-analytics":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "oci-apps":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "gcp-proxy":{"Unknown":{"reason":"tcp :22 probe failed"}}}}}'
fixture_one='{"version":1,"generated_at":"2026-09-16T05:12:42Z","fleet_state":{"vms":{
  "oci-mail":"Running",
  "oci-analytics":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "oci-apps":{"Unknown":{"reason":"tcp :22 probe failed"}},
  "gcp-proxy":{"Unknown":{"reason":"tcp :22 probe failed"}}}},
  "vms":[{"name":"oci-mail","uptime":"up 3 weeks"},{"name":"oci-analytics","uptime":""},
         {"name":"oci-apps","uptime":""},{"name":"gcp-proxy","uptime":""}]}'
# The #391 shape: every :22 answers (so every VM classifies RunningUnverified,
# i.e. "reached"), but the runner's ssh refuses its own config — "Bad owner or
# permissions on /root/.ssh/config" — so not one host returns SSH-collected
# data. Measured for real 2026-09-24 in cloud-data run 36022330282: "hosts
# reached: 4 of 4" printed beside "L3 Platform: ssh=0/4", with oci-mail's
# uptime, disk and container list all empty.
fixture_tcp_only='{"version":1,"generated_at":"2026-09-24T15:54:38Z","fleet_state":{"vms":{
  "oci-mail":{"RunningUnverified":{"reason":"oci CLI has no usable credentials; TCP :22 up"}},
  "oci-analytics":{"RunningUnverified":{"reason":"oci CLI has no usable credentials; TCP :22 up"}},
  "oci-apps":{"RunningUnverified":{"reason":"oci CLI has no usable credentials; TCP :22 up"}},
  "gcp-proxy":{"RunningUnverified":{"reason":"gcloud CLI not installed; TCP :22 up"}}}},
  "vms":[{"name":"oci-mail","uptime":""},{"name":"oci-analytics","uptime":""},
         {"name":"oci-apps","uptime":""},{"name":"gcp-proxy","uptime":""}]}'

# ── Drive the real orchestrator against a stubbed master crate ────────────
# $1 = fixture JSON, or the empty string to write no snapshot at all.
# Echoes the orchestrator's exit status, and leaves its combined output in the
# file named by $OUTPUT_LOG. The log goes to a FILE, not a shell variable: this
# function is called inside a command substitution, whose subshell would
# discard any variable it assigned and leave the caller reading a stale one.
# The status is taken from the orchestrator itself and never from a pipeline,
# which would report the status of the last stage instead.
OUTPUT_LOG="$(mktemp)"
trap 'rm -f "$OUTPUT_LOG"' EXIT
run_orchestrator() {
    local fixture="$1" work rc
    work="$(mktemp -d)"
    mkdir -p "$work/src/cloud-health-full-daily" "$work/dist" "$work/bin"
    cp "$ORCHESTRATOR" "$work/src/build.sh"

    # Phase 0 shells out to cargo unless it detects the prebuilt image. The
    # binaries are irrelevant here — the stub crate replaces them — so a
    # no-op cargo keeps the scratch tree hermetic.
    printf '#!/bin/sh\nexit 0\n' > "$work/bin/cargo"

    # The stub master: writes the forced snapshot and exits 0, which is
    # precisely what the real binary did on the ARM runner.
    cat > "$work/src/cloud-health-full-daily/build.sh" <<'STUB'
#!/bin/sh
dist="$(cd "$(dirname "$0")/../.." && pwd)/dist"
case "${1:-}" in
    link) exit 0 ;;
    run)
        if [ -n "${FIXTURE_JSON:-}" ]; then
            printf '%s\n' "$FIXTURE_JSON" > "$dist/_run_state.json"
        fi
        echo "Fleet: (stub) wrote ${FIXTURE_JSON:+snapshot}${FIXTURE_JSON:-no snapshot}"
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$work/bin/cargo" "$work/src/cloud-health-full-daily/build.sh"

    FIXTURE_JSON="$fixture" PATH="$work/bin:$PATH" \
        sh "$work/src/build.sh" all >"$OUTPUT_LOG" 2>&1
    rc=$?
    rm -rf "$work"
    printf '%s' "$rc"
}

# ── 1. Zero reach must be fatal ───────────────────────────────────────────
rc="$(run_orchestrator "$fixture_zero")"
if [ "$rc" -ne 0 ]; then
    ok "0 of 4 reached -> exit $rc (non-zero)"
    if grep -q 'hosts reached: 0 of 4' "$OUTPUT_LOG"; then
        ok "and it names the count: $(grep -m1 'hosts reached' "$OUTPUT_LOG")"
    else
        bad "exited non-zero but never printed the reach count — the log must say what it reached"
    fi
else
    bad "0 of 4 reached -> exit 0. A report that reached nothing was published as a success (this is #374)."
    sed 's/^/      /' "$OUTPUT_LOG"
fi

# ── 2. A reachable host must still pass ───────────────────────────────────
rc="$(run_orchestrator "$fixture_one")"
if [ "$rc" -eq 0 ]; then
    ok "1 of 4 reached -> exit 0 (guard does not false-fire)"
else
    bad "1 of 4 reached -> exit $rc. The guard fails a run that DID reach a host."
    sed 's/^/      /' "$OUTPUT_LOG"
fi

# ── 3. No snapshot at all is also vacuity ─────────────────────────────────
rc="$(run_orchestrator "")"
if [ "$rc" -ne 0 ]; then
    ok "no _run_state.json -> exit $rc (non-zero)"
else
    bad "no _run_state.json -> exit 0. A run that recorded no fleet state proved nothing either."
    sed 's/^/      /' "$OUTPUT_LOG"
fi

# ── 4. TCP reach with zero SSH collection is also vacuity (#391) ─────────
rc="$(run_orchestrator "$fixture_tcp_only")"
if [ "$rc" -ne 0 ]; then
    ok "4 of 4 :22-reachable but 0 collected -> exit $rc (non-zero)"
else
    bad "4 of 4 :22-reachable, 0 collected -> exit 0. A runner whose ssh refused every host published a green report (#391)."
    sed 's/^/      /' "$OUTPUT_LOG"
fi

if [ "$FAILS" -ne 0 ]; then
    echo "✗ $FAILS assertion(s) failed" >&2
    exit 1
fi
echo "✓ zero-reach guard holds"
