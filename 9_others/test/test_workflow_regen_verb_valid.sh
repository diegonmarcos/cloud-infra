#!/usr/bin/env bash
# Test: every "Regenerate dist/" pre-step in cicd workflows uses a valid
# 9_others/build.sh verb.
#
# Surfaced 2026-04-27 (ship run 25010189292): 4 cicd templates ran
# `bash 9_others/build.sh config` — but `config` is not a valid verb;
# valid are: all|link-builds|consolidate|derive|test|clean|ship. The script
# printed Usage and exited 1 → "Detect changes" job aborted before reaching
# the matrix-build step → entire ship matrix never started.
#
# This tester reads the actual verb list from 9_others/build.sh's case
# statement and asserts every cicd workflow's regen invocation uses one
# of them. Catches future verb renames OR typos.
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
CICD_DIR="$REPO_ROOT/1_cicd/src/cicd"
CONFIG_BUILD="$REPO_ROOT/9_others/build.sh"

[ -d "$CICD_DIR" ] || { echo "::error::$CICD_DIR not found"; exit 1; }
[ -f "$CONFIG_BUILD" ] || { echo "::error::$CONFIG_BUILD not found"; exit 1; }

# Extract valid verbs from the case statement (e.g. `all)`, `derive)`).
# sed, not awk: the previous version used `match($0, re, arr)`, a gawk-only
# 3-argument form. GitHub's ubuntu runners ship mawk, where that is a syntax
# error — the extraction produced nothing and the test failed on every run
# regardless of the workflows' actual content.
VALID_VERBS=$(sed -n '/^case /,/^esac/p' "$CONFIG_BUILD" \
    | sed -nE 's/^[[:space:]]+([a-z][a-z-]*[a-z])\).*/\1/p' | sort -u)
if [ -z "$VALID_VERBS" ]; then
    echo "::error::Could not extract valid verbs from $CONFIG_BUILD case statement"
    exit 1
fi

FAIL=0
EXAMINED=0
for f in "$CICD_DIR"/*.yml; do
    [ -f "$f" ] || continue
    # Lines like:  run: bash 9_others/build.sh <verb>
    # Only consider lines that actually invoke the script — `run: bash 9_others/build.sh <verb>`.
    # Excludes `name:` lines that mention the script in human-readable comments.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        EXAMINED=$((EXAMINED + 1))
        verb=$(printf '%s' "$line" | sed -nE 's|.*bash 9_others/build\.sh ([a-z][a-z-]*).*|\1|p')
        if [ -z "$verb" ]; then
            continue
        fi
        if printf '%s\n' "$VALID_VERBS" | grep -qx "$verb"; then
            printf "  OK  %-30s uses valid verb: %s\n" "$(basename "$f")" "$verb"
        else
            printf "  FAIL %-30s uses INVALID verb: %s (valid: %s)\n" "$(basename "$f")" "$verb" "$(printf '%s' "$VALID_VERBS" | tr '\n' ' ')"
            FAIL=1
        fi
    done < <(grep -E 'bash 9_others/build\.sh [a-z]' "$f" || true)
done

if [ "$EXAMINED" -eq 0 ]; then
    echo "  (no 9_others/build.sh invocations found in any cicd template)"
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::At least one cicd template invokes 9_others/build.sh with an invalid verb"
    echo "Valid verbs (from $CONFIG_BUILD case statement):"
    printf '%s\n' "$VALID_VERBS" | sed 's/^/  - /'
    exit 1
fi

echo
echo "All cicd 9_others/build.sh invocations use valid verbs."
