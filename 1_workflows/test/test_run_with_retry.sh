#!/usr/bin/env bash
# Tester for run_with_retry helper in cloud-ship-nix-homemanager-engine.sh
# Engine bug fix: docker buildx --push stalls indefinitely on residential connections
# with large nix closures. The retry wrapper enforces a per-attempt deadline + N retries.
#
# Test cases:
#   1. Command succeeds first try → returns 0, single attempt logged
#   2. Command always times out → returns 124/137, N attempts logged
#   3. Command succeeds on retry 2 → returns 0, two attempts logged
#   4. Knobs are read from build.json (declarative)
set -euo pipefail
cd "$(dirname "$0")"

PASS=0
FAIL=0
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ── Stand up the helper in isolation ──────────────────────────────────────────
# Mock the engine context: log, get_config, BUILD_LOG_FILE, HM_USER (required field)
ENGINE_SRC="$(cd .. && pwd)/src/scripts/cloud-ship-nix-homemanager-engine.sh"
[ ! -f "$ENGINE_SRC" ] && { echo "FATAL: $ENGINE_SRC not found"; exit 1; }

setup_test() {
  local case_name="$1"
  TEST_BUILD_JSON="$WORK_DIR/$case_name.build.json"
  TEST_LOG="$WORK_DIR/$case_name.log"
  cat > "$TEST_BUILD_JSON"

  # Tiny shim that loads only the helper functions, not the top-level pipeline
  cat > "$WORK_DIR/$case_name.shim.sh" << SHIM
set -uo pipefail
CONFIG="$TEST_BUILD_JSON"
BUILD_LOG_FILE="$TEST_LOG"
: > "\$BUILD_LOG_FILE"
log() { printf '[%s] %s\n' "\$(date +%H:%M:%S)" "\$1" | tee -a "\$BUILD_LOG_FILE"; }
get_config() {
  [ ! -f "\$CONFIG" ] && return 0
  node -e "const c=require('\$CONFIG'); const v='\$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(v===false?'false':v===true?'true':String(v!=null?v:''))"
}
# Source only the run_with_retry function block (lines 89-128 of engine — extract by markers)
SHIM
  # Extract run_with_retry from engine source by line range
  sed -n '/^run_with_retry()/,/^}$/p' "$ENGINE_SRC" >> "$WORK_DIR/$case_name.shim.sh"
}

check() {
  local label="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] $label (expected=$expected, actual=$actual)"
    PASS=$(( PASS + 1 ))
  else
    echo "[FAIL] $label (expected=$expected, actual=$actual)"
    FAIL=$(( FAIL + 1 ))
  fi
}

# ── CASE 1: succeeds first try ────────────────────────────────────────────────
setup_test "case1_success_first" << 'JSON'
{ "build": { "retry": { "attempts": 3, "timeout_secs": 10, "backoff_secs": 1 } } }
JSON
echo "==> case1: command succeeds first try"
set +e
bash -c "source $WORK_DIR/case1_success_first.shim.sh && run_with_retry 'echo-test' echo hello-world"
exit_code=$?
set -e
check "case1: exit code" "0" "$exit_code"
attempts_logged=$(grep -c "attempt 1/3" "$WORK_DIR/case1_success_first.log" || echo 0)
check "case1: exactly 1 attempt logged" "1" "$attempts_logged"

# ── CASE 2: always times out ─────────────────────────────────────────────────
setup_test "case2_always_timeout" << 'JSON'
{ "build": { "retry": { "attempts": 2, "timeout_secs": 2, "backoff_secs": 1 } } }
JSON
echo ""
echo "==> case2: command always times out (sleep 30, timeout 2s, 2 attempts)"
START=$(date +%s)
set +e
bash -c "source $WORK_DIR/case2_always_timeout.shim.sh && run_with_retry 'stuck-cmd' sleep 30"
exit_code=$?
set -e
END=$(date +%s)
duration=$(( END - START ))
# Exit should be 124 (SIGTERM from timeout) or 137 (SIGKILL from --kill-after)
if [ "$exit_code" = "124" ] || [ "$exit_code" = "137" ]; then
  check "case2: exit code is timeout (124 or 137)" "timeout" "timeout"
else
  check "case2: exit code is timeout (124 or 137)" "timeout" "$exit_code"
fi
# Should take ~ (2 attempts × 2s timeout) + (1 backoff × 1s) = ~5s
if [ "$duration" -ge 5 ] && [ "$duration" -le 12 ]; then
  check "case2: duration in [5,12]s (actual ${duration}s)" "in-range" "in-range"
else
  check "case2: duration in [5,12]s (actual ${duration}s)" "in-range" "out-of-range"
fi
# Match the RUN-line specifically, not the TIMEOUT-line which also mentions attempt 2/2.
attempts_2_started=$(grep -c "RUN: stuck-cmd (attempt 2/2" "$WORK_DIR/case2_always_timeout.log" || echo 0)
check "case2: attempt 2 was started" "1" "$attempts_2_started"
final_fail=$(grep -c "FAILED after 2 attempts" "$WORK_DIR/case2_always_timeout.log" || echo 0)
check "case2: 'FAILED after 2 attempts' logged" "1" "$final_fail"

# ── CASE 2b: recovery hook fires between failed attempts ─────────────────────
setup_test "case2b_recovery_hook" << 'JSON'
{ "build": { "retry": { "attempts": 2, "timeout_secs": 1, "backoff_secs": 1 } } }
JSON
echo ""
echo "==> case2b: recovery hook executes between attempts"
HOOK_MARKER="$WORK_DIR/recovery_marker"
rm -f "$HOOK_MARKER"
set +e
RETRY_RECOVERY_CMD="echo recovered >> $HOOK_MARKER" \
  bash -c "source $WORK_DIR/case2b_recovery_hook.shim.sh && run_with_retry 'fail-cmd' false"
exit_code=$?
set -e
hook_fires=$(wc -l < "$HOOK_MARKER" 2>/dev/null || echo 0)
# 2 attempts, both fail → hook fires once (between attempts), not after the last
check "case2b: recovery hook fires once between 2 failed attempts" "1" "$hook_fires"
recovery_logged=$(grep -c "Recovery hook:" "$WORK_DIR/case2b_recovery_hook.log" || echo 0)
check "case2b: recovery hook logged once" "1" "$recovery_logged"

# ── CASE 3: defaults applied when build.json lacks knobs ─────────────────────
setup_test "case3_defaults" << 'JSON'
{}
JSON
echo ""
echo "==> case3: defaults apply when build.json has no .build.retry block"
set +e
bash -c "source $WORK_DIR/case3_defaults.shim.sh && run_with_retry 'default-knobs' true"
exit_code=$?
set -e
check "case3: exit code" "0" "$exit_code"
default_timeout=$(grep -oE "timeout [0-9]+s" "$WORK_DIR/case3_defaults.log" | head -1 | grep -oE '[0-9]+' || echo 0)
check "case3: default timeout = 1200s" "1200" "$default_timeout"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
