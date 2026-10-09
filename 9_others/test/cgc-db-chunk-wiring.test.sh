#!/usr/bin/env bash
# #888 chunk wiring in cloud-cgc-db-update.sh. The planner has its own test
# (cgc-db-chunk-plan.test.sh); this one pins the four update.sh decisions the spec
# (a0_docs/eng-specs/cgc-incremental-chunked.md) depends on, and proves each check can fail
# by mutating a copy of the script.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
check() { # $1 file → rc 0 when every property holds
  local f="$1"
  # 1. the chunk loop drops octocode's commit marker before every window
  awk '/^chunk_index_repo\(\)/,/^}/' "$f" | grep -q 'storage/git_metadata.lance' || { echo "  no git_metadata drop"; return 1; }
  # 2. the graphrag phase touches the new-work files, the semantic phase does not
  awk '/^chunk_index_repo\(\)/,/^}/' "$f" | grep -q '"\$MANIFEST_PHASE" = "graphrag" \] && chunk_touch_next' || { echo "  graphrag touch not phase-gated"; return 1; }
  # 3. the HEAD gate also consults the chunk state
  grep -q '\[ "\$cur" = "\$last" \] && chunk_gate_current "\$cur"' "$f" || { echo "  manifest gate ignores chunk state"; return 1; }
  # 4. a forced, not-converged chunk run publishes to the force tag, never :latest
  grep -A1 'to $(force_partial_tag) (forced, not converged' "$f" | tail -1 | grep -q 'REPO_TAG="$(force_partial_tag)"; checkpoint_publish' || { echo "  forced partial not routed to the force tag"; return 1; }
  grep -B4 'forced, not converged' "$f" | grep -q 'CGC_FORCE:-0}" = "1"' || { echo "  force routing not gated on CGC_FORCE"; return 1; }
  # 5. the forced graphrag purge is skipped for a resumed partial
  grep -q 'CGC_FORCE:-0}" = "1" \] && \[ "\${RESUMED_FORCE_PARTIAL:-0}" != "1" \]' "$f" || { echo "  purge would wipe a resumed partial"; return 1; }
  # 6. the gate function itself: converged state at HEAD skips, anything else runs
  local fn; fn=$(awk '/^chunk_gate_current\(\)/,/^}/' "$f")
  local H; H=$(mktemp -d)
  mkdir -p "$H/p1"
  (
    CHUNK_MODE=1 OCTO_HOME="$H" MANIFEST_PHASE=graphrag
    chunk_home_project() { echo p1; }
    chunk_state_path() { printf '%s/.cgc-chunks-%s.json\n' "$1" "$2"; }
    eval "$fn"
    chunk_gate_current abc && { echo "  gate skipped with no state"; exit 1; }
    echo '{"seen":"abc","stale_runs":0,"dirty":[]}' > "$H/p1/.cgc-chunks-graphrag.json"
    chunk_gate_current abc || { echo "  gate ran a converged repo"; exit 1; }
    echo '{"seen":"abc","stale_runs":2,"dirty":[]}' > "$H/p1/.cgc-chunks-graphrag.json"
    chunk_gate_current abc && { echo "  gate skipped an unconverged repo"; exit 1; }
    exit 0
  ) || { rm -rf "$H"; return 1; }
  rm -rf "$H"
  return 0
}
check "$UPD" || { echo FAIL; exit 1; }
echo "  ok: wiring holds on the real script"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mut() { sed "$2" "$UPD" > "$W/m.sh"; cmp -s "$W/m.sh" "$UPD" && { echo "FAIL: mutation $1 is stale"; exit 1; }
        check "$W/m.sh" >/dev/null && { echo "FAIL: mutation $1 survived"; exit 1; }; echo "  ok: mutation $1 caught"; }
mut no-marker-drop   's|storage/git_metadata.lance; do|storage/other.lance; do|'
mut touch-always     's|\[ "\$MANIFEST_PHASE" = "graphrag" \] && chunk_touch_next|true \&\& chunk_touch_next|'
mut gate-head-only   's|\[ "\$cur" = "\$last" \] && chunk_gate_current "\$cur"|[ "$cur" = "$last" ]|'
mut force-to-latest  '/forced, not converged — :latest/{n;s|( REPO_TAG="\$(force_partial_tag)"; checkpoint_publish "\$r" )|checkpoint_publish "$r"|}'
mut purge-resumed    's| && \[ "\${RESUMED_FORCE_PARTIAL:-0}" != "1" \]||'
mut gate-ignores-stale 's/"\$1|0|0" \]/"$1|$(jq -r .stale_runs "$_cg_sf")|0" ]/'
echo PASS
