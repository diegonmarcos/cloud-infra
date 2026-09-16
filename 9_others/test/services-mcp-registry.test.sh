#!/usr/bin/env bash
# Runs the cloud-services-mcp registry self-checks (#377, #378).
#
# The registry module physically lives in the PRE-RENAME tree
# (a_solutions/infra-api_c3-services-api/src/code/registry/) and is symlinked
# into infra-api_cloud-services-mcp. Two defects of the same shape have already
# shipped from that arrangement, and both were silent:
#
#   #371  Both loaders restated the peer map filename as the literal
#         "build-c3-services-api.json". The container was renamed, the literal
#         stopped matching, the registry loaded ZERO services, getBaseUrl()
#         returned null for every one of them, and every tool quietly fell back
#         to a hardcoded address. infra.matomo.* dialled 10.0.0.4 for weeks
#         while the declaration said 10.0.0.6. Nothing raised.
#
#   #378  The name is derived from build.json now, but the dev-tree fallback
#         derived it by walking up from the MODULE'S OWN location. Node
#         resolves symlinks, so that always landed back in the pre-rename tree
#         and re-derived the OLD name — silently, for every container that
#         borrows the module.
#
# Both self-checks print one line per assertion and a final count. This wrapper
# asserts the count actually appeared: a runner that dies on module resolution
# exits non-zero having printed nothing that looks like a failed assertion, and
# an earlier report on this very work was called green on exactly that basis.
#
# A missing self-check is a FAILURE, never a skip. That is the whole subject of
# #368 and there is no third outcome here.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY_DIR="$ROOT/a_solutions/infra-api_c3-services-api/src/code/registry"

if [ ! -d "$REGISTRY_DIR" ]; then
    echo "::error::registry source not found at $REGISTRY_DIR — cloud-u-containers is checked out into a_solutions by the workflow; without it these guards are unrun, not passing."
    exit 1
fi

command -v node >/dev/null || { echo "::error::node is required to run the registry self-checks"; exit 1; }

failed=0

for selfcheck in peer-map.selfcheck.mts summary.selfcheck.mts; do
    path="$REGISTRY_DIR/$selfcheck"
    if [ ! -f "$path" ]; then
        echo "::error::$selfcheck is missing from $REGISTRY_DIR"
        failed=$((failed + 1))
        continue
    fi

    echo "── $selfcheck ──"
    # Captured in ONE invocation so the exit status belongs to the self-check
    # and not to a pipe. `npx --yes tsx`: node --experimental-strip-types cannot
    # run these — the module under test imports with `.js` specifiers and the
    # loader dies before the first assertion.
    output="$(cd "$REGISTRY_DIR" && npx --yes tsx "$selfcheck" 2>&1)"
    status=$?
    echo "$output"

    if [ "$status" -ne 0 ]; then
        echo "::error::$selfcheck failed (exit $status)"
        failed=$((failed + 1))
        continue
    fi

    # Exit zero is necessary but not sufficient — the assertions must have run.
    if ! echo "$output" | grep -qE 'selfcheck: [0-9]+ assertions passed'; then
        echo "::error::$selfcheck exited 0 but never reported an assertion count. It did not run its assertions; treat this as red."
        failed=$((failed + 1))
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "::error::$failed registry self-check(s) failed"
    exit 1
fi

echo "cloud-services-mcp registry self-checks: all passed"
