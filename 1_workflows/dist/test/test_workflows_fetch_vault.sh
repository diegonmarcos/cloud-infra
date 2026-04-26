#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_workflows_fetch_vault.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: every CICD source workflow that runs `cloud-builder` via docker MUST
# call the fetch-vault composite action first. Without it, the runner has no
# ~/git/vault/vault-keys-docker.envfile and the cloud-builder image's baked
# compose.yaml aborts with `env file ... not found` (proven failure mode on
# 2026-04-25 ship runs).
#
# Source-level test: scans 1_workflows/src/cicd/*.yml (the templates), not
# .github/workflows/*.yml (the dist) — so the test fails the moment a new
# workflow forgets the action, before the build step regenerates dist.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CICD_DIR="$REPO_ROOT/1_workflows/src/cicd"

[ -d "$CICD_DIR" ] || { echo "::error::$CICD_DIR not found"; exit 1; }

FAIL=0
EXAMINED=0
for f in "$CICD_DIR"/*.yml; do
    [ -f "$f" ] || continue
    EXAMINED=$((EXAMINED + 1))
    base=$(basename "$f")

    # Heuristic: a workflow needs fetch-vault iff it spins up the cloud-builder
    # image. We grep for the image name OR for `cloud-builder` as a docker
    # compose service. ship-ghcr-images.yml uses docker/build-push-action
    # directly (no cloud-builder) — must NOT trigger this test.
    if ! grep -qE '(cloud-builder-x-deb-nixhm|cloud-builder ship|cloud-builder ship-hm|cloud-builder gen-configs)' "$f"; then
        continue
    fi

    if grep -qE 'uses:[[:space:]]+\./\.github/actions/fetch-vault' "$f"; then
        printf "  OK  %s — runs cloud-builder AND uses fetch-vault\n" "$base"
    else
        printf "  FAIL %s — runs cloud-builder but does NOT use ./.github/actions/fetch-vault\n" "$base"
        FAIL=1
    fi
done

if [ "$EXAMINED" -eq 0 ]; then
    echo "::error::No CICD templates found in $CICD_DIR"
    exit 1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::At least one workflow runs cloud-builder without fetching vault first."
    echo "Fix: add this step right after actions/checkout@v4:"
    echo
    echo "  - name: Fetch vault"
    echo "    uses: ./.github/actions/fetch-vault"
    echo "    with:"
    echo "      vault_deploy_key: \${{ secrets.VAULT_DEPLOY_KEY }}"
    exit 1
fi

echo
echo "All cloud-builder workflows fetch the vault before running."
