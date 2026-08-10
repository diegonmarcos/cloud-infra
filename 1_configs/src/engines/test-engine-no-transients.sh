#!/usr/bin/env bash
# test-engine-no-transients.sh — verify the ship engine does not leak transient
# artifacts into the git working tree.
#
# Two files the engine used to leak:
#   1) <service>/.docker-src-hash-new — consumed by step_build from a PRIOR ship
#   2) <service>/dist/build-step-compose-custom.sh — rsync'd to VM but never cleaned
#
# Both are now handled correctly:
#   1) step_docker writes dist/.docker-src-hash directly (no -new intermediate)
#   2) step_deploy_compose generates the script in a tmpdir and removes on EXIT
#
# This test scans the whole cloud/ repo for either pattern and fails if found.

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}/cloud"
FAILS=0

scan() {
    pat="$1"
    found=$(find "$REPO/a_solutions" -maxdepth 4 -name "$pat" -type f 2>/dev/null || true)
    if [ -n "$found" ]; then
        echo "✗ leaked transient ($pat):"
        echo "$found" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
    else
        echo "✓ no $pat leaks"
    fi
}

scan '.docker-src-hash-new'
scan 'build-step-compose-custom.sh'

if [ $FAILS -gt 0 ]; then
    echo "✗ engine leaked $FAILS transient type(s) — re-run build+ship, they should not come back"
    exit 1
fi

echo "✓ engine produces no transient leaks"
