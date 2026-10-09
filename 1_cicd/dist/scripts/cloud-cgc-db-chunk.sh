#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-cgc-db-chunk.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-chunk.sh — chunk planner for the cgc octocode index (#888)
# ──────────────────────────────────────────────────────────────────────────
#  Sourced by cloud-cgc-db-update.sh. POSIX sh + git + jq only, no octocode.
#  Spec: a0_docs/eng-specs/cgc-incremental-chunked.md
#
#  Why this exists, measured on octocode 0.22.0 (src/indexer/mod.rs):
#   * A file whose mtime moved but whose blocks are unchanged produces no
#     embedding batch, so its file_metadata row is only written by the final
#     flush of a COMPLETED run. A run that times out records nothing for those
#     files and the next run walks them again. cloud-u-android sat at ~13.6k
#     indexed files across runs 37685693199 and 37843203892 for that reason.
#   * The graph pass only runs after the walk ends, over the blocks of files
#     processed in that run. A walk that never finishes never graphs anything.
#  So every octocode run has to COMPLETE. The planner bounds each run to a
#  window: the files already done, the files that changed, and the next chunk
#  of the sorted remainder. Everything else is excluded from the walk.
#
#  The window goes into .git/info/exclude, never into the root .noindex:
#  octocode's deleted-file cleanup (cleanup_deleted_files_optimized) builds its
#  matcher from the ROOT .gitignore + .noindex only, and deletes every indexed
#  row that matcher ignores. The walker also honours .git/info/exclude
#  (WalkBuilder.git_exclude(true)), the cleanup does not, so files outside the
#  window are skipped without being deleted. Files deleted from the tree are
#  still removed (the cleanup checks existence first).
#
#  State lives in <project dir>/.cgc-chunks-<phase>.json so it travels in the
#  repo's own GHCR image with the DB it describes:
#    {"v":1,"phase":"semantic","seen":"<commit>","chunk":2000,
#     "done":[sorted paths],"dirty":[sorted paths],"stale_runs":0}
#  done  = files a COMPLETED run processed in this phase (only grows, minus
#          files that left the tree)
#  dirty = files changed since `seen` (git diff), reprocessed first
# ──────────────────────────────────────────────────────────────────────────

CHUNK_EXCL_BEGIN="# >>> cgc-chunk window (cloud-cgc-db-chunk.sh) >>>"
CHUNK_EXCL_END="# <<< cgc-chunk window <<<"

# Remove our window block from .git/info/exclude, keeping everything else
# (exclude_submodules writes there too).
chunk_exclude_clear() {  # $1 = repo dir
  _cx="$1/.git/info/exclude"
  [ -f "$_cx" ] || return 0
  awk -v b="$CHUNK_EXCL_BEGIN" -v e="$CHUNK_EXCL_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip' "$_cx" > "$_cx.tmp" && mv "$_cx.tmp" "$_cx"
}

# Indexable files, sorted (LC_ALL=C): tracked, not a gitlink, not matched by the
# root .noindex or by any git ignore source. That is what octocode's walker can
# reach. Run it with our window block cleared, or it would hide the remainder.
#
# The two ignore sources are asked SEPARATELY and unioned. octocode registers
# .noindex as a custom ignore file (WalkBuilder::add_custom_ignore_filename), and
# the ignore crate ranks custom ignore files above every .gitignore, so a .noindex
# match wins even against a gitignore `!` re-include. Passed to git as one
# --exclude-from list it ranked BELOW the .gitignore files instead: cloud-u-android's
# root `!ab_cloud-libs-shared/libs/**` re-included 1151 files .noindex excludes
# (png, dict, fonts), which counted as indexable work octocode never walks (#888).
chunk_indexable() {  # $1 = repo dir → stdout: one path per line
  _ci_d="$1"
  _ci_ign=$(mktemp)
  {
    git -C "$_ci_d" -c core.quotepath=off ls-files -c -i --exclude-standard 2>/dev/null
    [ -f "$_ci_d/.noindex" ] && \
      git -C "$_ci_d" -c core.quotepath=off ls-files -c -i --exclude-from="$_ci_d/.noindex" 2>/dev/null
  } | LC_ALL=C sort -u > "$_ci_ign"
  git -C "$_ci_d" -c core.quotepath=off ls-files -s 2>/dev/null \
    | awk '$1 != "160000" { sub(/^[^\t]*\t/, ""); print }' \
    | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$_ci_ign"
  rm -f "$_ci_ign"
}

chunk_state_path() {  # $1 = dir holding the state, $2 = phase
  printf '%s/.cgc-chunks-%s.json\n' "$1" "${2:-default}"
}

chunk_state_read() {  # $1 = state file → stdout: state JSON (default when absent/invalid)
  if [ -s "$1" ] && jq -e '.v == 1 and (.done | type == "array")' "$1" >/dev/null 2>&1; then
    cat "$1"
  else
    printf '{"v":1,"seen":"","chunk":0,"done":[],"dirty":[],"stale_runs":0}\n'
  fi
}

# Escape a literal path as an anchored gitignore pattern.
chunk_glob_escape() {  # stdin paths → stdout patterns
  sed -e 's/[][\\*?!#]/\\&/g' -e 's/^/\//' -e 's/ $/\\ /'
}

# Plan one window. Writes:
#   $out/window   files octocode may walk this run (sorted)
#   $out/next     the new-work part of the window (dirty ∪ chunk) — the files
#                 the graphrag phase touches so octocode re-feeds them
#   $out/state    the state with dirty refreshed (NOT yet committed)
#   $out/todo_n   files still outstanding before this window
# and the exclude block in .git/info/exclude. Prints one summary line.
# $5 = optional allowlist: when set, chunk candidates are limited to it (the
#      graphrag phase passes the semantic phase's done set, so the graph never
#      runs ahead of the embeddings).
chunk_plan() {  # $1 repo dir  $2 state file  $3 head  $4 chunk size  $5 allowlist file|""  $6 out dir
  _cp_d="$1"; _cp_sf="$2"; _cp_head="$3"; _cp_n="$4"; _cp_allow="$5"; _cp_o="$6"
  mkdir -p "$_cp_o"
  chunk_exclude_clear "$_cp_d"
  chunk_indexable "$_cp_d" > "$_cp_o/indexable"
  chunk_state_read "$_cp_sf" > "$_cp_o/state0"
  jq -r '.done[]'  "$_cp_o/state0" | LC_ALL=C sort -u > "$_cp_o/done0"
  jq -r '.dirty[]' "$_cp_o/state0" | LC_ALL=C sort -u > "$_cp_o/dirty0"
  _cp_seen=$(jq -r '.seen // ""' "$_cp_o/state0")
  # Changes since the last planned commit. A seen commit we cannot resolve
  # (history rewritten, first run) re-verifies everything done: unchanged
  # files cost a hashmap lookup in octocode's walk, so this is cheap.
  : > "$_cp_o/changed"
  if [ -n "$_cp_seen" ] && [ "$_cp_seen" != "$_cp_head" ]; then
    if git -C "$_cp_d" cat-file -e "$_cp_seen^{commit}" 2>/dev/null; then
      git -C "$_cp_d" -c core.quotepath=off diff --name-only --no-renames "$_cp_seen" "$_cp_head" 2>/dev/null \
        | LC_ALL=C sort -u > "$_cp_o/changed"
    else
      cp "$_cp_o/done0" "$_cp_o/changed"
    fi
  fi
  # dirty := (dirty ∪ changed) ∩ done ∩ indexable — a changed file that was
  # never done is plain todo; a file gone from the tree is octocode's cleanup's.
  LC_ALL=C sort -u "$_cp_o/dirty0" "$_cp_o/changed" | LC_ALL=C comm -12 - "$_cp_o/done0" \
    | LC_ALL=C comm -12 - "$_cp_o/indexable" > "$_cp_o/dirty"
  LC_ALL=C comm -12 "$_cp_o/done0" "$_cp_o/indexable" > "$_cp_o/done"
  LC_ALL=C comm -23 "$_cp_o/indexable" "$_cp_o/done" > "$_cp_o/remaining"
  if [ -n "$_cp_allow" ]; then
    LC_ALL=C sort -u "$_cp_allow" | LC_ALL=C comm -12 "$_cp_o/remaining" - > "$_cp_o/cand"
  else
    cp "$_cp_o/remaining" "$_cp_o/cand"
  fi
  head -n "$_cp_n" "$_cp_o/cand" > "$_cp_o/chunk"
  LC_ALL=C sort -u "$_cp_o/dirty" "$_cp_o/chunk" > "$_cp_o/next"
  LC_ALL=C sort -u "$_cp_o/done" "$_cp_o/next" > "$_cp_o/window"
  # Everything indexable outside the window is hidden from this walk.
  _cx="$_cp_d/.git/info/exclude"
  mkdir -p "$_cp_d/.git/info"
  {
    printf '%s\n' "$CHUNK_EXCL_BEGIN"
    LC_ALL=C comm -23 "$_cp_o/indexable" "$_cp_o/window" | chunk_glob_escape
    printf '%s\n' "$CHUNK_EXCL_END"
  } >> "$_cx"
  _cp_rem=$(wc -l < "$_cp_o/remaining" | tr -d ' ')
  _cp_dn=$(wc -l < "$_cp_o/dirty" | tr -d ' ')
  echo $(( _cp_rem + _cp_dn )) > "$_cp_o/todo_n"
  jq --rawfile dirty "$_cp_o/dirty" --rawfile done "$_cp_o/done" \
     '.dirty = ($dirty | split("\n") | map(select(length > 0)))
      | .done = ($done | split("\n") | map(select(length > 0)))' \
     "$_cp_o/state0" > "$_cp_o/state"
  printf '[cgc-chunk] plan: indexable=%s done=%s dirty=%s remaining=%s chunk=%s window=%s\n' \
    "$(wc -l < "$_cp_o/indexable" | tr -d ' ')" "$(wc -l < "$_cp_o/done" | tr -d ' ')" \
    "$_cp_dn" "$_cp_rem" "$(wc -l < "$_cp_o/chunk" | tr -d ' ')" "$(wc -l < "$_cp_o/window" | tr -d ' ')"
}

# A window COMPLETED (octocode rc=0): its files are done, its dirty files are
# clean, `seen` moves to the commit the window was planned at.
chunk_commit() {  # $1 plan out dir  $2 head  $3 state file to write
  _cc_o="$1"
  LC_ALL=C sort -u "$_cc_o/done" "$_cc_o/next" > "$_cc_o/done1"
  jq --rawfile done "$_cc_o/done1" --arg head "$2" \
     '.done = ($done | split("\n") | map(select(length > 0)))
      | .dirty = [] | .seen = $head | .stale_runs = 0' \
     "$_cc_o/state" > "$3.tmp" && mv "$3.tmp" "$3"
}

# Nothing outstanding after this window?
chunk_converged() {  # $1 state file  $2 indexable file  $3 allowlist file|"" → rc 0 when converged
  _cv_t=$(mktemp)
  jq -r '.done[]' "$1" | LC_ALL=C sort -u > "$_cv_t"
  _cv_left=$(LC_ALL=C comm -23 "$2" "$_cv_t" | wc -l | tr -d ' ')
  _cv_dirty=$(jq '.dirty | length' "$1")
  rm -f "$_cv_t"
  [ "$_cv_left" = "0" ] && [ "$_cv_dirty" = "0" ]
}

# Adapt the chunk size to the time a chunk took. Halve on a timeout (a window
# that cannot finish makes no durable progress at all), grow when a chunk used
# under a quarter of the slice, otherwise keep. Clamped to [min, max].
chunk_adapt() {  # $1 current  $2 outcome: timeout|ok  $3 seconds taken  $4 slice seconds  $5 min  $6 max → stdout new size
  _ca_n="$1"
  case "$2" in
    timeout) _ca_n=$(( _ca_n / 2 )) ;;
    ok) [ "$4" -gt 0 ] && [ $(( $3 * 4 )) -lt "$4" ] && _ca_n=$(( _ca_n * 2 )) ;;
  esac
  [ "$_ca_n" -lt "$5" ] && _ca_n="$5"
  [ "$6" -gt 0 ] && [ "$_ca_n" -gt "$6" ] && _ca_n="$6"
  [ "$_ca_n" -ge 1 ] || _ca_n=1
  echo "$_ca_n"
}

# graphrag phase: bump the mtime of the window's new-work files by one second so
# octocode re-feeds them (already-embedded blocks are fetched, not re-embedded,
# and pushed into the graph builder; see process_file_differential). A later
# semantic run restores the commit mtime, which is <= the stored one, so the
# bump never causes a re-embed.
chunk_touch_next() {  # $1 repo dir  $2 next-file list
  while IFS= read -r _ct_f; do
    [ -n "$_ct_f" ] && [ -e "$1/$_ct_f" ] || continue
    _ct_m=$(stat -c %Y "$1/$_ct_f" 2>/dev/null) || continue
    touch -h -d "@$(( _ct_m + 1 ))" "$1/$_ct_f" 2>/dev/null || true
  done < "$2"
}

# One JSON status line per repo+phase — the convergence monitor's record.
chunk_status_json() {  # $1 repo  $2 phase  $3 state file  $4 indexable file  $5 head  $6 converged(0/1)
  _cs_t=$(mktemp)
  jq -r '.done[]' "$3" | LC_ALL=C sort -u > "$_cs_t"
  _cs_left=$(LC_ALL=C comm -23 "$4" "$_cs_t" | wc -l | tr -d ' ')
  rm -f "$_cs_t"
  jq -c --arg repo "$1" --arg phase "$2" --arg head "$5" --argjson conv "$6" \
        --argjson total "$(wc -l < "$4" | tr -d ' ')" --argjson left "$_cs_left" \
     '{repo: $repo, phase: $phase, head: $head, seen: .seen, total: $total,
       done: (.done | length), remaining: $left, dirty: (.dirty | length),
       chunk: .chunk, stale_runs: .stale_runs, converged: ($conv == 1)}' "$3"
}
