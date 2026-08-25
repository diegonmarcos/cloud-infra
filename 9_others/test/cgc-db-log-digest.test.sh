#!/bin/sh
# Regression test for octo_log_digest in cloud-cgc-db-update.sh.
#
# The bug this guards (runs 32721840450 / 32746314822): the index branches
# replayed `tail -4` of octocode's log. octocode's progress spinner is ONE
# \n-terminated line made of thousands of \r-separated frames, and every
# eprintln it emits lands glued onto the current frame. So `tail -4` showed a
# healthy spinner and hid every "Warning: AI architectural analysis failed"
# that came before its last line -- the graphrag phase shipped graphs with
# zero LLM relationships as green jobs, and not one log line said why.
# This test EXECUTES the real function, extracted verbatim from the script,
# on a synthetic log shaped exactly like octocode's output, and also proves
# that the old `tail -4` idiom loses the warning on that same input.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

awk '/^octo_log_digest\(\) \{/ { f=1 } f { print } f && /^\}$/ { exit }' "$SCRIPT" > "$T/fn.sh"
ck "function extracted from script" "$(grep -c 'octo_log_digest() {' "$T/fn.sh")" "1"
. "$T/fn.sh"

# A log the way octocode really writes it: ESC[K erase sequences, braille
# spinner, \r between frames, a warning glued onto a frame, then the final line.
esc=$(printf '\033'); cr=$(printf '\r')
{
  printf '%s\n' "✓ Git repository detected: /repos/x"
  printf '%s[K⠋ Indexing: 1/85 files (1%%)%s' "$esc" "$cr"
  printf '%s[K⠙ Indexing: 5/85 files (5%%), GraphRAG: 3 blocks - Processing file: a/b.jsonInfo: AI analyzing 34 files for architectural relationships\n' "$esc"
  printf '%s[K⠹ Indexing: 6/85 files (7%%), GraphRAG: 8 blocks - Processing file: c/d.tsWarning: AI architectural analysis failed: boom\n' "$esc"
  # what a real run prints after that warning: the description batch dying, its
  # fallback, and the per-file leftovers -- enough lines to push the warning out
  # of any `tail -4`, exactly as happened in CI.
  printf '%s[K⠸ Indexing: 6/85 files (7%%), GraphRAG: 8 blocks - Processing file: c/d.ts⚠️  Batch AI description failed for 8 files: Failed to parse batch response: expected value at line 1 column 1\n' "$esc"
  printf '%s[K⠼ Indexing: 6/85 files (7%%), GraphRAG: 8 blocks - Processing file: c/d.ts🔄 Falling back to individual AI calls...\n' "$esc"
  printf '%s[K⠴ Indexing: 6/85 files (7%%), GraphRAG: 8 blocks - Processing file: c/d.ts⚠️  Missing descriptions for 3 files: ["a", "b", "c"]\n' "$esc"
  printf '%s[K⠦ Indexing: 6/85 files (7%%), GraphRAG: 8 blocks - Processing file: c/d.tsDebug: No files qualified for AI relationship analysis in this batch\n' "$esc"
  printf '%s[K⠸ Indexing: 6/85 files (7%%) - Processing relationships: 2 of 590 batches completed%s' "$esc" "$cr"
  printf '%s[K⠼ Indexing: 6/85 files (7%%) - Processing relationships: 2 of 590 batches completed%s' "$esc" "$cr"
  printf '%s[K✓ Indexing complete! 6 of 85 files processed, GraphRAG: 10 blocks\n' "$esc"
} > "$T/octo.log"

octo_log_digest "$T/octo.log" 40 > "$T/digest"
ck "digest keeps the glued Warning line"      "$(grep -c 'Warning: AI architectural analysis failed: boom' "$T/digest")" "1"
ck "digest keeps the glued Info line"         "$(grep -c 'Info: AI analyzing 34 files' "$T/digest")" "1"
ck "digest keeps the glued emoji lines"       "$(grep -c 'Batch AI description failed\|Falling back to individual\|Missing descriptions' "$T/digest")" "3"
ck "digest keeps the completion line"         "$(grep -c 'Indexing complete! 6 of 85' "$T/digest")" "1"
ck "digest drops every spinner frame"         "$(grep -c 'Indexing: [0-9]' "$T/digest")" "0"
ck "digest strips ANSI erase sequences"       "$(grep -c "$esc" "$T/digest")" "0"
ck "digest honours the line cap"              "$(octo_log_digest "$T/octo.log" 2 | wc -l | tr -d ' ')" "2"
# The idiom being replaced loses the warning on this very input -- that is the bug.
ck "old tail -4 idiom hides the Warning"      "$(tail -4 "$T/octo.log" | grep -c 'Warning: AI architectural' || true)" "0"

# No branch may fall back to a bare tail of the raw log.
ck "no index branch tails the raw octocode log" \
   "$(grep -cE 'tail -[0-9]+ "\$_log"' "$SCRIPT" || true)" "0"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
