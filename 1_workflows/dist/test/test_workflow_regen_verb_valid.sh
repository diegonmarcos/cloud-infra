#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_workflow_regen_verb_valid.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: every "Regenerate dist/" pre-step in cicd workflows uses a valid
# 2_configs/build.sh verb.
#
# Surfaced 2026-04-27 (ship run 25010189292): 4 cicd templates ran
# `bash 2_configs/build.sh config` — but `config` is not a valid verb;
# valid are: all|link-builds|consolidate|derive|test|clean|ship. The script
# printed Usage and exited 1 → "Detect changes" job aborted before reaching
# the matrix-build step → entire ship matrix never started.
#
# This tester reads the actual verb list from 2_configs/build.sh's case
# statement and asserts every cicd workflow's regen invocation uses one
# of them. Catches future verb renames OR typos.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CICD_DIR="$REPO_ROOT/1_workflows/src/cicd"
CONFIG_BUILD="$REPO_ROOT/2_configs/build.sh"

[ -d "$CICD_DIR" ] || { echo "::error::$CICD_DIR not found"; exit 1; }
[ -f "$CONFIG_BUILD" ] || { echo "::error::$CONFIG_BUILD not found"; exit 1; }

# Extract valid verbs from the case statement (e.g. `all)`, `derive)`).
VALID_VERBS=$(awk '/^\s*case "?\$\{?1/,/esac/{ if (match($0, /^[[:space:]]+([a-z][a-z-]*[a-z])\)/, a)) print a[1] }' "$CONFIG_BUILD" | sort -u)
if [ -z "$VALID_VERBS" ]; then
    echo "::error::Could not extract valid verbs from $CONFIG_BUILD case statement"
    exit 1
fi

FAIL=0
EXAMINED=0
for f in "$CICD_DIR"/*.yml; do
    [ -f "$f" ] || continue
    # Lines like:  run: bash 2_configs/build.sh <verb>
    # Only consider lines that actually invoke the script — `run: bash 2_configs/build.sh <verb>`.
    # Excludes `name:` lines that mention the script in human-readable comments.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        EXAMINED=$((EXAMINED + 1))
        verb=$(printf '%s' "$line" | sed -nE 's|.*bash 2_configs/build\.sh ([a-z][a-z-]*).*|\1|p')
        if [ -z "$verb" ]; then
            continue
        fi
        if printf '%s\n' "$VALID_VERBS" | grep -qx "$verb"; then
            printf "  OK  %-30s uses valid verb: %s\n" "$(basename "$f")" "$verb"
        else
            printf "  FAIL %-30s uses INVALID verb: %s (valid: %s)\n" "$(basename "$f")" "$verb" "$(printf '%s' "$VALID_VERBS" | tr '\n' ' ')"
            FAIL=1
        fi
    done < <(grep -E 'bash 2_configs/build\.sh [a-z]' "$f" || true)
done

if [ "$EXAMINED" -eq 0 ]; then
    echo "  (no 2_configs/build.sh invocations found in any cicd template)"
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::At least one cicd template invokes 2_configs/build.sh with an invalid verb"
    echo "Valid verbs (from $CONFIG_BUILD case statement):"
    printf '%s\n' "$VALID_VERBS" | sed 's/^/  - /'
    exit 1
fi

echo
echo "All cicd 2_configs/build.sh invocations use valid verbs."
