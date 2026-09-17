#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_every_tester_is_registered.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Every tester under 9_others/test/ must be named by something that runs it.
#
# The gap this closes (#368, 2026-09-16): a tester becomes part of CI by having
# a hand-written step in 1_cicd/src/cicd/*.yml that names its filename. Writing
# the tester and forgetting the step produces no error anywhere. The file is
# committed, it is executable, `ls 9_others/test/` shows it next to the ones
# that do run, and the pipeline stays green because the pipeline never knew it
# existed. 43 of 101 testers were in exactly that state when this was written —
# including eight that name a production incident and a run id in their own
# header, so the incident they were written to guard went unguarded from the
# day the guard was committed.
#
# Nothing detected that, because every check in the pipeline ran in the
# registered → file direction (test_lint_pipeline_referenced_files_tracked.sh
# proves every referenced file exists and is executable). This is the missing
# direction: file → registered.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="$ROOT/9_others/test-registry.json"
WORKFLOWS="$ROOT/1_cicd/src/cicd"

# Workflow SOURCES, not .github/workflows/ — src is what a human edits and what
# the engine renders from. Checking the generated copy would let a src-only
# regression pass until the next build.
[ -d "$WORKFLOWS" ] || { echo "::error::no workflow sources at $WORKFLOWS"; exit 1; }
[ -f "$REGISTRY" ] || { echo "::error::no tester registry at $REGISTRY"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq is required to read the tester registry"; exit 1; }

registered=0; unregistered=0; resolved=0; dangling=0

registered_in_json() {  # registered_in_json <basename>
    jq -e --arg n "$1" '.testers | has($n)' "$REGISTRY" >/dev/null 2>&1
}

referenced_by_workflow() {  # referenced_by_workflow <basename>
    grep -rqF -- "$1" "$WORKFLOWS"/*.yml 2>/dev/null
}

# A tester is test_*.sh or *.test.sh. Both conventions are in live use here.
# Anything else in this directory is a helper (wg_group_jobs.py is a resolver
# library imported by test_wg_group_lock_bounded.sh, not a tester) and is out
# of scope on purpose — a helper has no exit status anyone should be reading.
echo "── every tester is named by a runner ──"
seen=0
for t in "$ROOT"/9_others/test/test_*.sh "$ROOT"/9_others/test/*.test.sh; do
    [ -e "$t" ] || continue
    base="$(basename "$t")"
    seen=$((seen + 1))

    if referenced_by_workflow "$base" || registered_in_json "$base"; then
        registered=$((registered + 1))
    else
        echo "  ✗ $base is executed by nothing — no step in 1_cicd/src/cicd/*.yml names it, and it has no entry in 9_others/test-registry.json"
        unregistered=$((unregistered + 1))
    fi
done

# The reverse rot: an entry left behind after its tester was deleted. Left
# unchecked, the registry slowly becomes a list of files that are not there,
# and its count stops meaning anything. An entry may name a tester outside
# 9_others/test/ via the "path" key (e.g. the b_infra protection suite) — the
# path is repo-root-relative, exactly as run-registered-testers.sh reads it.
echo "── every registry entry names a tester that exists ──"
while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    if [ -n "$path" ]; then
        tester="$ROOT/$path"
    else
        tester="$ROOT/9_others/test/$name"
    fi
    if [ -f "$tester" ]; then
        resolved=$((resolved + 1))
    else
        echo "  ✗ 9_others/test-registry.json lists $name, but ${tester#$ROOT/} does not exist"
        dangling=$((dangling + 1))
    fi
done < <(jq -r '.testers | to_entries[] | [.key, (.value.path // "")] | @tsv' "$REGISTRY")

# A glob that matched nothing would reach the summary with fail=0 and pass, which
# is the same fail-green shape this test exists to catch.
[ "$seen" -gt 0 ] || { echo "::error::found no testers at all under 9_others/test/ — the glob is wrong, not the tree"; exit 1; }

echo "── $seen testers: $registered registered, $unregistered unregistered ── registry: $resolved entries resolve, $dangling dangling ──"
fail=$((unregistered + dangling))
if [ "$fail" -gt 0 ]; then
    echo "::error::$fail problem(s): $unregistered tester(s) under 9_others/test/ are executed by nothing, and $dangling registry entry/entries name a file that is not there. Add each unregistered tester to 9_others/test-registry.json (status \"run\", or \"quarantine\" with the reason it is red) — do NOT add another hand-written step to lint-pipeline.yml, that hardcoded list is what produced this gap."
    exit 1
fi
