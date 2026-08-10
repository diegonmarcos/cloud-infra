#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Pre-commit tester — GHA workflow YAMLs with "secret" in name     ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   The pre-commit content-scan allows workflow YAMLs under the    ║
# ║   engine paths (.github/workflows/, 1_configs/src/deploy/gha/cicd/,       ║
# ║   1_configs/dist/) whose filename mentions secrets BUT whose   ║
# ║   content is a proper GHA workflow (has `on:` and `jobs:`).      ║
# ║                                                                  ║
# ║   Non-workflow files with secret-ish names must still be blocked.║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_precommit_allows_gha_...   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$REPO_ROOT/1_configs/dist/hooks/pre-commit"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

# Set up a throwaway git repo so the hook has a real staging area.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
git commit -q --allow-empty -m "root"
mkdir -p .github/workflows

# ── Case 1: GHA workflow YAML with "secrets" in name → must PASS ─────
cat > .github/workflows/lint-secrets-coverage.yml <<'YML'
name: lint-secrets-coverage
on:
  pull_request:
  workflow_dispatch:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YML
git add .github/workflows/lint-secrets-coverage.yml
if bash "$HOOK" >/dev/null 2>&1; then
    pass "GHA workflow with 'secrets' in name: allowed"
else
    fail "GHA workflow wrongly blocked"
fi
git reset -q HEAD -- .

# ── Case 2: plaintext secret-shaped YAML at same path → must BLOCK ───
cat > .github/workflows/password-stash.yml <<'YML'
password: plaintext-oh-no
api_key: AKIA1234567890
YML
git add .github/workflows/password-stash.yml
if bash "$HOOK" >/dev/null 2>&1; then
    fail "non-workflow plaintext secret wrongly allowed (no on:/jobs:)"
else
    pass "non-workflow plaintext secret: blocked"
fi
git reset -q HEAD -- .

# ── Case 3: workflow YAML outside allowed paths → must BLOCK ─────────
mkdir -p random/
cat > random/secrets.yml <<'YML'
on:
  push:
jobs:
  x:
    steps: []
YML
git add random/secrets.yml
if bash "$HOOK" >/dev/null 2>&1; then
    fail "file outside engine paths wrongly allowed"
else
    pass "secret-named file outside engine paths: blocked"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "pre-commit GHA workflow allow-list: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "pre-commit GHA workflow allow-list: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
