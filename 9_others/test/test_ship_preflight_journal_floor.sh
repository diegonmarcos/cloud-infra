#!/usr/bin/env bash
# #413: the HM ship pre-flight cleanup is an automatic journal-vacuum path too.
# It ran `journalctl --vacuum-size=50M` — delete-by-volume, any age — which is
# the exact call that erased 16 days of oci-apps journal. Every vacuum there must
# be --vacuum-time at the floor declared in config.json.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-step-deploy-activate.sh"
CODE=$(sed 's/[[:space:]]*#.*$//' "$SRC")   # rationale comments name the banned flag
fail=0
if printf '%s\n' "$CODE" | grep -qE -- '--vacuum-(size|files)'; then
  echo "FAIL: ship pre-flight vacuums the journal by size/files"; fail=1
fi
n=$(printf '%s\n' "$CODE" | grep -c 'journalctl --vacuum' || true)
good=$(printf '%s\n' "$CODE" | grep -cF -- 'journalctl --vacuum-time=${JOURNAL_FLOOR_DAYS}d' || true)
if [ "$n" -eq 0 ] || [ "$n" -ne "$good" ]; then
  echo "FAIL: $good of $n journal vacuums use --vacuum-time=\${JOURNAL_FLOOR_DAYS}d"; fail=1
fi
printf '%s\n' "$CODE" | grep -qE "JOURNAL_FLOOR_DAYS=.*native\.protection\.journal_retention_floor_days" \
  || { echo "FAIL: JOURNAL_FLOOR_DAYS not read from native.protection.journal_retention_floor_days"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: ship pre-flight journal vacuum honours the declared floor"
exit "$fail"
