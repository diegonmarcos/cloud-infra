#!/usr/bin/env bash
# CI gate — fails non-zero if any secrets.yaml lacks a _credentials block
# or has uncovered keys. Wrapper over audit-credentials-coverage.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Secrets coverage lint"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if "$SCRIPT_DIR/audit-credentials-coverage.sh"; then
  echo ""
  echo "✅ All secrets.yaml files have a complete _credentials block."
  exit 0
else
  echo ""
  echo "❌ Secrets coverage gaps detected."
  echo "   See: a_solutions/_shared/secrets-schema.md"
  exit 1
fi
