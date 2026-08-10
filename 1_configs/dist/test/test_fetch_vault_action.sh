#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/test/test_fetch_vault_action.sh
# ║   Engine : 1_configs/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_fetch_vault_action.sh — verify the fetch-vault composite action
# correctly asserts every output file cloud-builder needs.
#
# The original CI breakage: vault/build.sh env was supposed to generate
# 6 dialect files (bash.env, fish.fish, systemd.envfile, docker.envfile,
# systemd.yaml, pub.json). The action only checked vault-keys-bash.env.
# When generation partially failed (or output dir mismatched), the action
# passed but cloud-builder's compose.yaml — which mounts vault-keys-docker.envfile
# via env_file: — aborted with "env file ... not found".
#
# This tester reads the SOURCE action file (not the deployed one) and
# asserts:
#   1. The "Generate" step verifies BOTH vault-keys-bash.env AND
#      vault-keys-docker.envfile exist after `build.sh env`.
#   2. The "Verify" step checks scalar keys in docker.envfile too.
#   3. The "Clone vault" step uses VAULT_DEPLOY_KEY (declarative input).
#   4. The action wires fetch-vault into all 4 cicd templates that run
#      cloud-builder via docker compose.

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}/cloud"
ACTION="$REPO/1_configs/src/gha/actions/fetch-vault/action.yml"
CICD_DIR="$REPO/1_configs/src/gha/cicd"
FAILS=0

[ -f "$ACTION" ] || { echo "✗ source action.yml not found at $ACTION"; exit 1; }

# 1. Generate step asserts BOTH bash.env and docker.envfile exist
if ! grep -q 'vault-keys-docker\.envfile not generated' "$ACTION"; then
    echo "✗ Generate step doesn't assert vault-keys-docker.envfile (the file cloud-builder mounts)"
    FAILS=$((FAILS + 1))
else
    echo "✓ Generate step asserts vault-keys-docker.envfile"
fi

if ! grep -q 'vault-keys-bash\.env not generated' "$ACTION"; then
    echo "✗ Generate step doesn't assert vault-keys-bash.env"
    FAILS=$((FAILS + 1))
else
    echo "✓ Generate step asserts vault-keys-bash.env"
fi

# 2. Verify step also checks docker.envfile scalar keys
if ! grep -q 'DOCKER_ENV.*docker\.envfile' "$ACTION"; then
    echo "✗ Verify step doesn't reference docker.envfile"
    FAILS=$((FAILS + 1))
else
    echo "✓ Verify step references docker.envfile"
fi

# 3. Clone step uses VAULT_DEPLOY_KEY declarative input (not hardcoded)
if ! grep -q 'inputs\.vault_deploy_key' "$ACTION"; then
    echo "✗ Clone step doesn't use inputs.vault_deploy_key"
    FAILS=$((FAILS + 1))
else
    echo "✓ Clone step uses inputs.vault_deploy_key (declarative)"
fi

# 4. fetch-vault is wired into every cicd ship-*.yml template that runs
#    cloud-builder. Discovered from disk (no hardcoded allowlist) so retiring
#    or adding a ship template doesn't require editing this test.
shopt -s nullglob
SHIP_TPLS=("$CICD_DIR"/ship*.yml)
shopt -u nullglob
[ ${#SHIP_TPLS[@]} -gt 0 ] || { echo "✗ no ship-*.yml templates found in $CICD_DIR"; FAILS=$((FAILS + 1)); }
for f in "${SHIP_TPLS[@]}"; do
    tpl=$(basename "$f")
    # Only assert templates that actually invoke cloud-builder; non-builder
    # ship templates don't need vault.
    grep -q 'cloud-builder' "$f" || { echo "· $tpl does not invoke cloud-builder — skipped"; continue; }
    if ! grep -q 'uses:.*fetch-vault' "$f"; then
        echo "✗ $tpl invokes cloud-builder but does not call ./.github/actions/fetch-vault — cloud-builder will fail"
        FAILS=$((FAILS + 1))
    else
        echo "✓ $tpl wires fetch-vault"
    fi
done

# 5. Source ↔ deployed parity (engine compiles src → .github/actions/)
DEPLOYED="$REPO/.github/actions/fetch-vault/action.yml"
if [ -f "$DEPLOYED" ]; then
    # Strip the GENERATED-FILE banner from deployed before diff (declarative
    # banner injected by the engine — not in source).
    if diff -q "$ACTION" <(awk '/^name:/{p=1} p' "$DEPLOYED") >/dev/null 2>&1; then
        echo "✓ deployed action matches source (banner-stripped)"
    else
        echo "✗ deployed action drifts from source — run 1_configs/build.sh"
        FAILS=$((FAILS + 1))
    fi
else
    echo "✗ deployed action missing — run 1_configs/build.sh"
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test_fetch_vault_action: PASS"
    exit 0
else
    echo "test_fetch_vault_action: FAIL ($FAILS check(s))"
    exit 1
fi
