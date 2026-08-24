#!/usr/bin/env bash
# Test: cloud-ship-container-step-secrets-decrypt.sh writes .secrets to
# $DIST_DIR (service root), NOT $DIST_DIR/compose.
#
# step_compose forces `docker compose --project-directory .` (cwd = service
# root), so the YAML's `env_file: [".secrets"]` resolves to
# /opt/containers/<svc>/.secrets — the service root, not compose/.
#
# History:
# - 2026-04-27 morning: thought v2 layout needed compose/.secrets — was wrong.
#   That fix (commit b97a9a459) caused cloud-mail-mcp to fail compose with:
#     env file /opt/containers/cloud-mail-mcp/.secrets not found
# - 2026-04-27 afternoon: reverted to $DIST_DIR/.secrets after surfacing
#   the --project-directory . pin in deploy-compose.sh:89 (ship run 24998852451).
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-secrets-decrypt.sh"

[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

FAIL=0

# 1) Must NOT route SECRETS_DIR into $DIST_DIR/compose — that broke compose
#    when --project-directory . is in effect.
if grep -qE 'SECRETS_DIR=.*DIST_DIR/compose' "$SCRIPT"; then
    printf "  FAIL step_secrets routes SECRETS_DIR to \$DIST_DIR/compose — incompatible with --project-directory . in step_compose\n"
    FAIL=1
else
    printf "  OK  no compose/ subdir routing for SECRETS_DIR\n"
fi

# 2) SECRETS_DIR must be set to $DIST_DIR (or the artifacts must use $DIST_DIR
#    directly — either is fine; the rule is "service root, not compose/").
if grep -qE 'SECRETS_DIR="\$DIST_DIR"' "$SCRIPT" || grep -qE '\$DIST_DIR/\.secrets"?' "$SCRIPT"; then
    printf "  OK  step_secrets writes .secrets to \$DIST_DIR (service root)\n"
else
    printf "  FAIL step_secrets does not write .secrets to \$DIST_DIR\n"
    FAIL=1
fi

# 3) The three artifacts (.secrets, .secrets.json, .secrets.d) must all use
#    SECRETS_DIR (or $DIST_DIR directly).
ARTIFACT_REFS=$(grep -cE '\$(SECRETS_DIR|DIST_DIR)/(\.secrets|\.secrets\.json|\.secrets\.d)' "$SCRIPT" || true)
if [ "$ARTIFACT_REFS" -ge 4 ]; then
    printf "  OK  all three artifacts written via service-root path (%d refs)\n" "$ARTIFACT_REFS"
else
    printf "  FAIL expected at least 4 artifact path refs, found %d\n" "$ARTIFACT_REFS"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::secrets-decrypt path regression"
    exit 1
fi

echo
echo "step_secrets writes to \$DIST_DIR/.secrets (service root) — compatible with step_compose's --project-directory ."
