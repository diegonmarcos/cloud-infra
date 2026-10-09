#!/usr/bin/env bash
# Tester for the cgc chunk planner (#888, spec a0_docs/eng-specs/cgc-incremental-chunked.md).
#
# THE FAILURE IT GUARDS: octocode 0.22 only records skip state for touched-but-unchanged
# files at the end of a COMPLETED run, and only graphs after the walk ends. A repo too big
# for one slice therefore never advanced (cloud-u-android: ~13.6k files on two runs two days
# apart). The planner bounds each run to a window that can finish. These properties must hold:
#   1. the window is done ∪ dirty ∪ next chunk of the sorted remainder, deterministic;
#   2. the rest is hidden through .git/info/exclude, never the root .noindex (octocode's
#      deleted-file cleanup deletes every indexed row the ROOT .noindex matches);
#   3. a completed window grows done monotonically and clears dirty;
#   4. a changed done file becomes dirty; a deleted file leaves done; a rename is a
#      delete plus a new todo file;
#   5. the graphrag allowlist keeps the graph behind the embeddings;
#   6. the planner converges.
# Each property is then re-checked against a MUTATED copy of the library, which must fail:
# a test that cannot go red proves nothing.
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
LIB="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-chunk.sh"
[ -f "$LIB" ] || { echo "::error::chunk library not found at $LIB"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq required"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

mkrepo() { # $1 dir: 10 code files, a noindexed dist/, a submodule-like gitlink is skipped
  local d="$1" i
  mkdir -p "$d/src" "$d/dist"
  git -C "$d" init -q 2>/dev/null || git init -q "$d"
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  for i in 0 1 2 3 4 5 6 7 8 9; do echo "f$i" > "$d/src/f$i.ts"; done
  echo x > "$d/dist/out.js"; echo "x" > "$d/src/[odd] name.ts"
  printf 'dist/\n' > "$d/.noindex"
  git -C "$d" add -A && git -C "$d" commit -qm init
}

# run_suite <lib> → prints ok/FAIL lines, returns number of failures
run_suite() {
  local lib="$1" fails=0 R="$WORK/r$RANDOM" O H S
  (
    # shellcheck disable=SC1090
    . "$lib"
    f() { echo "  FAIL: $1"; exit 1; }
    mkrepo "$R"; H=$(git -C "$R" rev-parse HEAD); S="$R/state.json"; O="$WORK/o$RANDOM"
    git -C "$R" add -A >/dev/null 2>&1

    # 1 + 2: first window is the first 4 sorted indexable files, rest excluded via info/exclude
    chunk_plan "$R" "$S" "$H" 4 "" "$O" >/dev/null
    [ "$(wc -l < "$O/indexable")" = 12 ] || f "indexable count $(wc -l < "$O/indexable") != 12 (.noindex'd dist/ must be out, .noindex itself in)"
    grep -q '^dist/' "$O/indexable" && f "noindexed dist/ counted as indexable"
    [ "$(cat "$O/window")" = "$(head -4 "$O/indexable")" ] || f "window is not the first 4 sorted files"
    grep -q 'src/f9.ts' "$R/.git/info/exclude" || f "remainder not hidden in .git/info/exclude"
    grep -q 'src/f' "$R/.noindex" && f "window written to the root .noindex (octocode cleanup would delete indexed rows)"
    grep -qF '/src/\[odd\] name.ts' "$R/.git/info/exclude" || grep -q 'odd' "$O/window" || f "special-char path not escaped"
    # replanning must not stack blocks
    chunk_plan "$R" "$S" "$H" 4 "" "$O" >/dev/null
    [ "$(grep -c '>>> cgc-chunk' "$R/.git/info/exclude")" = 1 ] || f "exclude block stacked on replan"

    # 3: commit grows done; next plan picks the next 4
    chunk_commit "$O" "$H" "$S"
    [ "$(jq '.done|length' "$S")" = 4 ] || f "done not 4 after first commit"
    chunk_plan "$R" "$S" "$H" 4 "" "$O" >/dev/null
    [ "$(wc -l < "$O/chunk")" = 4 ] && [ "$(wc -l < "$O/window")" = 8 ] || f "second window not done(4)+chunk(4)"
    chunk_commit "$O" "$H" "$S"

    # 4: change a done file, delete a done file, rename a done file
    first=$(jq -r '.done[0]' "$S"); second=$(jq -r '.done[1]' "$S"); third=$(jq -r '.done[2]' "$S")
    echo changed >> "$R/$first"; git -C "$R" rm -q "$R/$second"; git -C "$R" mv "$R/$third" "$R/src/zz-renamed.ts"
    git -C "$R" commit -qam change; H2=$(git -C "$R" rev-parse HEAD)
    chunk_plan "$R" "$S" "$H2" 4 "" "$O" >/dev/null
    grep -qxF "$first" "$O/dirty" || f "changed done file not dirty"
    grep -qxF "$second" "$O/window" && f "deleted file still in window"
    grep -qxF "$third" "$O/done" && f "renamed-away path still done"
    grep -qxF "src/zz-renamed.ts" "$O/remaining" || f "rename target not todo"
    chunk_commit "$O" "$H2" "$S"
    [ "$(jq '.dirty|length' "$S")" = 0 ] || f "dirty not cleared by commit"
    [ "$(jq -r .seen "$S")" = "$H2" ] || f "seen not advanced"

    # 5: allowlist keeps the chunk inside it
    S2="$R/state2.json"; printf 'src/f5.ts\n' > "$WORK/allow"
    chunk_plan "$R" "$S2" "$H2" 50 "$WORK/allow" "$O" >/dev/null
    [ "$(cat "$O/chunk")" = "src/f5.ts" ] || f "allowlist not honoured: $(tr '\n' ' ' < "$O/chunk")"

    # 6: converges in bounded runs
    n=0
    while ! chunk_converged "$S" "$O/indexable" ""; do
      n=$((n+1)); [ "$n" -gt 10 ] && f "did not converge in 10 windows"
      chunk_plan "$R" "$S" "$H2" 4 "" "$O" >/dev/null; chunk_commit "$O" "$H2" "$S"
    done
    [ "$(jq '.done|length' "$S")" = "$(wc -l < "$O/indexable")" ] || f "converged with done != indexable"

    # adapt
    [ "$(chunk_adapt 2000 timeout 0 100 100 20000)" = 1000 ] || f "timeout must halve"
    [ "$(chunk_adapt 2000 ok 10 100 100 20000)" = 4000 ] || f "fast chunk must double"
    [ "$(chunk_adapt 2000 ok 60 100 100 20000)" = 2000 ] || f "normal chunk must keep"
    [ "$(chunk_adapt 150 timeout 0 100 100 20000)" = 100 ] || f "min clamp"
    echo "  ok: all planner properties hold"
  ) || fails=1
  return $fails
}

echo "== real library"
run_suite "$LIB" || { echo FAIL; exit 1; }

# ── mutations: each must turn the suite red ─────────────────────────────────
mutate() { # $1 name  $2 sed expression
  local m="$WORK/mut-$1.sh"
  sed "$2" "$LIB" > "$m"
  cmp -s "$m" "$LIB" && { echo "::error::mutation $1 did not change the library (stale sed)"; exit 1; }
  echo "== mutation: $1"
  if run_suite "$m" >/dev/null 2>&1; then echo "  FAIL: mutation $1 survived"; exit 1; fi
  echo "  ok: mutation $1 caught"
}
mutate window-in-root-noindex 's|_cx="\$_cp_d/.git/info/exclude"$|_cx="$_cp_d/.noindex"|'
mutate commit-drops-done      's|sort -u "\$_cc_o/done" "\$_cc_o/next" > "\$_cc_o/done1"|sort -u "$_cc_o/next" > "$_cc_o/done1"|'
mutate no-dirty-from-diff     's|LC_ALL=C sort -u "\$_cp_o/dirty0" "\$_cp_o/changed"|LC_ALL=C sort -u "$_cp_o/dirty0"|'
mutate deleted-stays-done     's|LC_ALL=C comm -12 "\$_cp_o/done0" "\$_cp_o/indexable" > "\$_cp_o/done"|cp "$_cp_o/done0" "$_cp_o/done"|'
mutate allowlist-ignored      's|if \[ -n "\$_cp_allow" \]; then|if false; then|'
mutate block-not-cleared      's|^  chunk_exclude_clear "\$_cp_d"$|  :|'
mutate timeout-grows          's|timeout) _ca_n=\$(( _ca_n / 2 ))|timeout) _ca_n=$(( _ca_n * 2 ))|'
echo PASS
