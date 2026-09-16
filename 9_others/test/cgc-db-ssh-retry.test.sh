#!/bin/sh
# Regression test for ssh_retry in cgc-db-index.yml's restore-all step.
#
# The bug this guards (run 32746314822): the helper read `$?` after a BARE ssh.
# The step runs under `set -eu`, where a failing bare command kills the shell
# on the spot -- the capture line never ran, the loop never looped, and one
# transient rc=255 became instant job death with zero retries and no log line.
# The fix is the `|| _sr_rc=$?` capture (a "tested" failure is exempt from -e).
# This test EXECUTES the real function, extracted verbatim from the yml, under
# set -eu with a stubbed ssh -- a grep for the idiom would not catch a future
# rewrite that reintroduces the trap some other way.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
YML="$ROOT/1_cicd/src/cicd/cgc-db-index.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# Extract the function body (10-space yml indent stripped), stop at its brace.
awk '
  /^          ssh_retry\(\) \{/ { f=1 }
  f { line=$0; sub(/^          /,"",line); print line }
  f && /^          \}$/ { exit }
' "$YML" > "$T/fn.sh"
ck "function extracted from yml" "$(grep -c 'ssh_retry() {' "$T/fn.sh")" "1"

# Harness: set -eu like the real step; sleep neutralized; ssh stubbed by a
# per-case script that reads its plan from files.
run_case() { # $1=plan (space-separated rcs, last one repeats)  -> prints "rc=<n> calls=<n> retries=<n>"
  printf '%s\n' $1 > "$T/plan"; : > "$T/calls"
  (
    set -eu
    HOST=testhost
    CGC_SSH_OPTS=""
    sleep() { :; }
    ssh() {
      echo x >> "$T/calls"
      _n=$(wc -l < "$T/calls")
      _rc=$(sed -n "${_n}p" "$T/plan")
      [ -n "$_rc" ] || _rc=$(sed -n '$p' "$T/plan")
      cat >/dev/null   # consume the stdin feed like real ssh would
      return "$_rc"
    }
    . "$T/fn.sh"
    rc=0
    ssh_retry /dev/null target 'true' >"$T/out" 2>&1 || rc=$?
    echo "rc=$rc calls=$(wc -l < "$T/calls" | tr -d ' ') retries=$(grep -c 'unreachable' "$T/out" || true)"
  )
}

# A) two connection failures then success: must retry twice and succeed.
ck "255,255,0 -> succeeds after 2 retries" "$(run_case '255 255 0')" "rc=0 calls=3 retries=2"
# B) remote command really failed (rc=7): no retry, rc propagated.
ck "7 -> returns 7 immediately, no retry" "$(run_case '7')" "rc=7 calls=1 retries=0"
# C) permanent 255: exhausts 20 attempts and returns 255, not 1.
ck "255 forever -> 20 attempts then rc=255" "$(run_case '255')" "rc=255 calls=20 retries=19"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
