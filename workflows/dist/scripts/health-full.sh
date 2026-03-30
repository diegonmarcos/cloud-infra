#!/usr/bin/env bash
# ── Full 11-layer cloud health check ──
# Runs cloud-health-full-report (Rust) on oci-apps via SSH.
# The binary lives in cloud-data/cloud-health-stack/cloud-health-full-report/
# and reads cloud-data JSONs from the same repo.
set -uo pipefail

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "=== Cloud Health Full Report (11-Layer) ==="
echo "Running on oci-apps via SSH..."
echo ""

# The binary is pre-built on oci-apps in ~/git/cloud-data/cloud-health-stack/
# If not built, cargo build it first (takes ~30s on ARM)
REPORT_DIR="/home/ubuntu/git/cloud-data/cloud-health-stack/cloud-health-full-report"

RESULT=$($SSH oci-apps bash -c "
  cd $REPORT_DIR 2>/dev/null || { echo 'ERROR: $REPORT_DIR not found'; exit 1; }

  # Build if no binary or source changed
  if [ ! -f target/release/cloud-health-full ] || [ src/main.rs -nt target/release/cloud-health-full ]; then
    echo '[build] Compiling cloud-health-full-report...' >&2
    cargo build --release 2>&1 | tail -3 >&2
  fi

  # Run the binary
  target/release/cloud-health-full 2>&1
" 2>&1)

EXIT_CODE=$?

echo "$RESULT"
echo ""

# Parse results
TOTAL=$(echo "$RESULT" | grep -oP '\d+ passed' | grep -oP '\d+' || echo 0)
FAILED=$(echo "$RESULT" | grep -oP '\d+ failed' | grep -oP '\d+' || echo 0)
CRITICAL=$(echo "$RESULT" | grep -c 'CRITICAL' || echo 0)

echo "─────────────────────────────────────"
echo "SUMMARY: $TOTAL passed, $FAILED failed, $CRITICAL critical"

# Fail on critical issues or SSH failure
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "##[error]Health check SSH/execution failed (exit $EXIT_CODE)"
  exit 1
fi

if [ "$CRITICAL" -gt 0 ]; then
  echo "##[error]$CRITICAL CRITICAL issues detected"
  exit 1
fi

# Warn on non-critical failures but don't fail the workflow
if [ "$FAILED" -gt 0 ]; then
  echo "##[warning]$FAILED non-critical checks failed"
fi

exit 0
