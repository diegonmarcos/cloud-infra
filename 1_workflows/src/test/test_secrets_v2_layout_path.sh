#!/usr/bin/env bash
# Test: cloud-ship-container-step-secrets-decrypt.sh writes .secrets to the
# correct path for the v2 layout (dist/compose/.secrets), not dist/.secrets.
#
# Bug surfaced 2026-04-27: compose YAML in v2 services declares
# `env_file: [".secrets"]` (relative), which resolves to compose/.secrets.
# The engine wrote to dist/.secrets, so docker compose aborted on the VM:
#   env file /opt/containers/<svc>/compose/.secrets not found
#
# Two manifestations: c3-services-mcp + mail-mcp both at HTTP 502.
# Fix: layout-aware $SECRETS_DIR via the LAYOUT_V2 flag exported by
# cloud-ship-container-engine.sh (already present pre-fix at line 151).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/1_workflows/src/scripts/cloud-ship-container-step-secrets-decrypt.sh"

[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

FAIL=0

# 1) Script must reference LAYOUT_V2 so the path is layout-aware.
if grep -q 'LAYOUT_V2' "$SCRIPT"; then
    printf "  OK  step_secrets reads LAYOUT_V2\n"
else
    printf "  FAIL step_secrets does not reference LAYOUT_V2 — secrets path is not layout-aware\n"
    FAIL=1
fi

# 2) Script must derive a SECRETS_DIR variable that lands inside compose/ for v2.
if grep -qE 'SECRETS_DIR=.*DIST_DIR/compose' "$SCRIPT"; then
    printf "  OK  step_secrets sets SECRETS_DIR=\$DIST_DIR/compose for v2\n"
else
    printf "  FAIL step_secrets does not set SECRETS_DIR to dist/compose for v2 — env_file: [\".secrets\"] won't resolve\n"
    FAIL=1
fi

# 3) The three artifacts (.secrets, .secrets.json, .secrets.d) must use
#    SECRETS_DIR, not the raw DIST_DIR — otherwise the v1 path leaks.
for artifact in '\.secrets"' '\.secrets\.json"' '\.secrets\.d'; do
    DIST_USES=$(grep -c -- "DIST_DIR/${artifact}" "$SCRIPT" 2>/dev/null | head -1)
    DIST_USES=${DIST_USES:-0}
    if [ "$DIST_USES" -gt 0 ]; then
        printf "  FAIL %s still references \$DIST_DIR — should be \$SECRETS_DIR\n" "${artifact}"
        FAIL=1
    fi
done

# 4) Confirm SECRETS_DIR is referenced for all three artifacts (smoke check —
#    catches an accidental rename to a different var name).
SECRETS_DIR_REFS=$(grep -cE '\$SECRETS_DIR/(\.secrets|\.secrets\.json|\.secrets\.d)' "$SCRIPT" || true)
if [ "$SECRETS_DIR_REFS" -ge 4 ]; then
    printf "  OK  all three artifacts written via \$SECRETS_DIR (%d refs)\n" "$SECRETS_DIR_REFS"
else
    printf "  FAIL expected at least 4 \$SECRETS_DIR/.secrets* refs, found %d\n" "$SECRETS_DIR_REFS"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::secrets-decrypt v2 layout path regression"
    exit 1
fi

echo
echo "step_secrets writes to compose/.secrets when LAYOUT_V2=1 — env_file: [\".secrets\"] resolves correctly."
