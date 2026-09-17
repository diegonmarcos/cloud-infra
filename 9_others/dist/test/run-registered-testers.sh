#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/run-registered-testers.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Runs every tester listed in 9_others/test-registry.json.
#
# Why this exists (#368, 2026-09-16): lint-pipeline.yml registers a tester by
# carrying a hand-written YAML step that names its filename. 43 of the 101
# testers under 9_others/test/ had no such step. They were committed, they were
# executable, they looked like coverage in a directory listing, and nothing had
# ever run them — including eight guards whose own headers name the production
# incident they were written for, with the run id. Adding 43 more YAML steps
# would have been extending the hardcoded list that caused the gap. The list is
# data now, and this is the one step that reads it.
#
# Two statuses, and neither of them can swallow an exit code:
#
#   run         the tester's exit status is the verdict. Non-zero fails the job.
#
#   quarantine  the tester is KNOWN red and is still executed, and is asserted
#               to STILL BE RED. A quarantined tester that starts passing fails
#               this job and says so, because the only thing worse than a red
#               guard is a quarantine entry that outlived its reason and turned
#               into a permanent silent skip.
#
# There is deliberately no third status. `continue-on-error`, `|| true` and
# "report-only" are how a green run comes to mean nothing, which is the whole
# subject of this ticket.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="$ROOT/9_others/test-registry.json"

[ -f "$REGISTRY" ] || { echo "::error::test-registry.json not found at $REGISTRY"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq is required to read the tester registry"; exit 1; }

ran=0; failed=0; quarantined=0; revived=0; missing=0

while IFS=$'\t' read -r name status reason path; do
    [ -n "$name" ] || continue
    # read collapses consecutive IFS delimiters, so jq below emits "-" for
    # missing fields instead of the empty string that would shift the columns.
    [ "$reason" = "-" ] && reason=""
    [ "$path" = "-" ] && path=""
    if [ -n "$path" ]; then
        tester="$ROOT/$path"
    else
        tester="$ROOT/9_others/test/$name"
    fi

    # A registry entry naming a file that is not there is a failure, not a skip.
    # Skipping it is how a deleted tester keeps reading as coverage.
    if [ ! -f "$tester" ]; then
        echo "::error::$name is in test-registry.json but ${tester#$ROOT/} does not exist"
        missing=$((missing + 1))
        continue
    fi

    # Through its own shebang, never a hardcoded `sh`: these are bash scripts
    # using arrays and herestrings, and forcing dash turns them into a syntax
    # error that exits non-zero and reads exactly like a real verdict.
    [ -x "$tester" ] || chmod +x "$tester" 2>/dev/null || true

    out="$(mktemp)"
    "$tester" >"$out" 2>&1; rc=$?
    ran=$((ran + 1))

    case "$status" in
        run)
            if [ "$rc" -eq 0 ]; then
                echo "  ok         $name"
            else
                echo "::group::FAIL $name (exit $rc)"
                cat "$out"
                echo "::endgroup::"
                echo "::error::$name failed (exit $rc)"
                failed=$((failed + 1))
            fi
            ;;
        quarantine)
            if [ "$rc" -ne 0 ]; then
                echo "  quarantined $name (exit $rc) — $reason"
                quarantined=$((quarantined + 1))
            else
                echo "::group::REVIVED $name"
                cat "$out"
                echo "::endgroup::"
                echo "::error::$name is quarantined but now PASSES — set its status to \"run\" in 9_others/test-registry.json and delete its reason. Reason on file: $reason"
                revived=$((revived + 1))
            fi
            ;;
        *)
            echo "::error::$name has unknown status \"$status\" in test-registry.json (expected \"run\" or \"quarantine\")"
            failed=$((failed + 1))
            ;;
    esac
    rm -f "$out"
done < <(jq -r '.testers | to_entries[] | [.key, .value.status, (.value.reason // "-"), (.value.path // "-")] | @tsv' "$REGISTRY")

echo "── registered testers: $ran ran, $failed failed, $quarantined quarantined, $revived revived, $missing missing ──"

# A registry that resolved to nothing would print a clean summary and pass.
[ "$ran" -gt 0 ] || { echo "::error::the registry executed no testers at all — that is a broken registry, not a green run"; exit 1; }

[ $((failed + revived + missing)) -eq 0 ]
