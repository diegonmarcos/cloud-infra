#!/usr/bin/env bash
# Tester for #888: a graphrag-phase index that persisted no graph must be reported, and a
# forced run's unfinished index must be resumable without ever replacing :latest.
#
# THE FAILURE IT GUARDS: run 37415858605 (forced graphrag, cloud-u-containers) hit the
# 282-min slice at 2233/3462 files, published a project dir with storage but no
# graphrag_nodes, and finished GREEN -- the timeout branch only warned and the 0-node
# overview passed assert_llm_graph as a "small corpus". octocode-export then found no
# project for the repo and kg-store kept an older graph.
#
# The functions are extracted from cloud-cgc-db-update.sh BY NAME and driven for real;
# the call-site wiring is pinned with structural greps because the loop body is not a function.
set -uo pipefail
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SH="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
[ -f "$SH" ] || { echo "::error::$SH not found"; exit 1; }
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

extract() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^\}$/{exit}' "$SH"; }
for fn in graph_nodes_present force_partial_tag resume_force_partial project_dirs_snapshot; do
  body="$(extract "$fn")"
  case "$body" in *"$fn()"*) eval "$body" ;; *) echo "::error::could not extract $fn() from $SH"; exit 1 ;; esac
done
FORCE_PARTIAL_MARKER="$(grep -E '^FORCE_PARTIAL_MARKER=' "$SH" | head -1 | cut -d'"' -f2)"
[ -n "$FORCE_PARTIAL_MARKER" ] || { echo "::error::FORCE_PARTIAL_MARKER missing"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OCTO_HOME="$WORK/home"; mkdir -p "$OCTO_HOME"

echo "graph_nodes_present"
mkdir -p "$OCTO_HOME/p_graph/storage/graphrag_nodes.lance/data" "$OCTO_HOME/p_graph/storage/graphrag_nodes.lance/_versions"
: > "$OCTO_HOME/p_graph/storage/graphrag_nodes.lance/data/abc.lance"
mkdir -p "$OCTO_HOME/p_empty/storage/graphrag_nodes.lance/data"
mkdir -p "$OCTO_HOME/p_nograph/storage/code_blocks.lance/data"; : > "$OCTO_HOME/p_nograph/storage/code_blocks.lance/data/x.lance"
graph_nodes_present p_graph   && ok "dir with a node fragment -> present" || bad "fragment not detected"
graph_nodes_present p_empty   && bad "empty data/ read as present" || ok "table dir without fragment -> absent"
graph_nodes_present p_nograph && bad "storage without graph read as present" || ok "storage with blocks but no graphrag_nodes -> absent (the 37415858605 shape)"
graph_nodes_present nope      && bad "missing dir read as present" || ok "missing project dir -> absent"
graph_nodes_present ""        && bad "empty name read as present" || ok "empty name -> absent"

echo "force-partial resume"
HERE="$WORK/bin"; mkdir -p "$HERE"
REPO_PREFIX="ghcr.io/x/cgc-db-"; REPO_TAG="latest"; MANIFEST_PHASE="graphrag"; OCTO_VERSION="0.22.0"
# Stub puller: "restores" whatever $STUB_SRC holds into the home, like CGC_PULL_MERGE=1 does.
cat > "$HERE/cloud-cgc-db-pull.sh" <<'STUB'
#!/bin/sh
[ -d "$STUB_SRC" ] && cp -a "$STUB_SRC"/. "$1"/
exit 0
STUB
export STUB_SRC="$WORK/src"
[ "$(force_partial_tag)" = "latest-force-graphrag" ] && ok "resume tag is per phase and never :latest" || bad "tag=$(force_partial_tag)"

run_case() { # $1=name $2=marker-json-or-empty
  rm -rf "$OCTO_HOME" "$STUB_SRC"; mkdir -p "$OCTO_HOME/fastembed" "$STUB_SRC/proj1/storage"
  [ -n "$2" ] && printf '%s' "$2" > "$STUB_SRC/proj1/$FORCE_PARTIAL_MARKER"
  resume_force_partial myrepo >/dev/null 2>&1
}
run_case good '{"octocode":"0.22.0","phase":"graphrag","commit":"c"}'
{ [ -d "$OCTO_HOME/proj1/storage" ] && [ ! -e "$OCTO_HOME/proj1/$FORCE_PARTIAL_MARKER" ]; } && ok "matching marker -> resumed, marker stripped so :latest never carries it" || bad "matching marker not resumed"
run_case oldver '{"octocode":"0.12.2","phase":"graphrag","commit":"c"}'
[ ! -e "$OCTO_HOME/proj1" ] && ok "other octocode version -> dropped (never layer across binaries)" || bad "cross-version partial kept"
run_case otherphase '{"octocode":"0.22.0","phase":"semantic","commit":"c"}'
[ ! -e "$OCTO_HOME/proj1" ] && ok "other phase -> dropped" || bad "cross-phase partial kept"
run_case nomarker ''
[ ! -e "$OCTO_HOME/proj1" ] && ok "tag without marker (finished run) -> dropped, from base" || bad "marker-less image kept"
[ -d "$OCTO_HOME/fastembed" ] && ok "root caches untouched" || bad "fastembed removed"

echo "call-site wiring"
t="$(awk '/elif \[ "\$_rc" = "124" \]; then/{f=1} f{print} f&&/^  else$/{exit}' "$SH")"
printf '%s' "$t" | grep -q 'graph_nodes_present' && ok "timeout branch checks for the graph" || bad "timeout branch does not check graph_nodes_present"
printf '%s' "$t" | grep -q 'NO_GRAPH_REPOS=' && ok "timeout branch records the graph-less repo" || bad "timeout branch does not record NO_GRAPH_REPOS"
printf '%s' "$t" | grep -q 'REPO_TAG="$(force_partial_tag)"' && ok "forced partial goes to the resume tag" || bad "forced partial not diverted from :latest"
r0="$(awk '/assert_llm_graph "\$d" "\$r" \|\| exit 1/{f=1} f{print} f&&/_noop_index" = "1"/{exit}' "$SH")"
printf '%s' "$r0" | grep -q 'graph_nodes_present' && printf '%s' "$r0" | grep -q 'exit 1' && ok "rc=0 path refuses a graph-less result" || bad "rc=0 path lacks the graph guard"
grep -q '^if \[ -n "\$NO_GRAPH_REPOS" \]; then' "$SH" && ok "run ends red when a repo persisted no graph" || bad "no end-of-run failure"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
