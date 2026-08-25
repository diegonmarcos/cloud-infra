#!/bin/sh
# Regression tests for the octocode pin (build.json .runtime.octocode.version /
# .release) and for assert_llm_graph in cloud-cgc-db-update.sh.
#
# Background (2026-08-25): octocode 0.12.2 discarded EVERY LLM relationship reply
# (bare serde parse of a ```json-fenced answer -> Ok(empty)), so the graphrag
# phase shipped structural-only graphs as green runs for weeks. The fix is the
# upstream 0.22 release, fetched by version + sha256 instead of the hand-built
# 0.12.2 GHCR images, plus a guard that refuses to publish a graphrag checkpoint
# with no LLM-derived relationship type. These tests keep both honest.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BJ="$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json"
SCRIPT="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
NIX="$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/src/compose.nix"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
hex64() { printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no; }

# ── 1) the pin: one version, one release, both arches hashed ────────────────
V=$(jq -r '.runtime.octocode.version // empty' "$BJ")
ck "version is a plain semver"            "$(printf '%s' "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo yes || echo no)" "yes"
ck "release.repo is upstream octocode"    "$(jq -r '.runtime.octocode.release.repo' "$BJ")" "Muvon/octocode"
ck "release.asset templates version+arch" "$(jq -r '.runtime.octocode.release.asset' "$BJ" | grep -q '{version}.*{arch}' && echo yes || echo no)" "yes"
ck "sha256.x86_64 is 64 hex"              "$(hex64 "$(jq -r '.runtime.octocode.release.sha256.x86_64 // empty' "$BJ")")" "yes"
ck "sha256.aarch64 is 64 hex"             "$(hex64 "$(jq -r '.runtime.octocode.release.sha256.aarch64 // empty' "$BJ")")" "yes"
ck "the 0.12-era image keys are gone"     "$(jq -r '.runtime.octocode | has("octocode_images")' "$BJ")" "false"
# The base image carries config.toml + model caches written BY the pinned binary; a
# bump that keeps `:latest` would restore a stale-schema config into every consumer.
ck "per_repo_publish.base_image tag == version" \
   "$(jq -r '.per_repo_publish.base_image' "$BJ" | sed 's/.*://')" "$V"

# ── 2) the producer really uses the pin ──────────────────────────────────────
grepq() { python3 -c "import sys;sys.exit(0 if sys.argv[1] in open(sys.argv[2],encoding='utf8').read() else 1)" "$1" "$2"; }
ck "ensure_octocode downloads the release asset" "$(grepq 'releases/download/$OCTO_VERSION' "$SCRIPT" && echo yes || echo no)" "yes"
ck "ensure_octocode verifies sha256 before install" "$(grepq '[ "$_got" = "$OCTO_SHA" ]' "$SCRIPT" && echo yes || echo no)" "yes"
ck "on-PATH octocode accepted only at the pinned version" "$(grepq '= "$OCTO_VERSION" ]' "$SCRIPT" && echo yes || echo no)" "yes"
ck "no docker extraction of a custom octocode image remains" "$(grep -c 'OCTO_IMAGE\|octocode_images' "$SCRIPT" || true)" "0"
# The FastEmbed probe must be read-only w.r.t. $OCTO_HOME: `models list` in a
# throwaway XDG home. The old probe ran `octocode index` in a scratch repo, which on
# 0.22 stamps octocode's OWN default config (jina code model) into the real home.
ck "FastEmbed probe uses models list in a throwaway XDG home" \
   "$(grep -c 'XDG_DATA_HOME="$_t" XDG_CONFIG_HOME="$_t" XDG_CACHE_HOME="$_t" "$1" models list' "$SCRIPT" || true)" "1"
ck "FastEmbed probe no longer runs octocode index" "$(grep -c '"$1" index' "$SCRIPT" || true)" "0"
# config.toml comes from the pinned binary itself (0.22 refuses a hand-written v1
# file: "missing field `quantization`"), never from a heredoc template.
ck "no heredoc config template survives"  "$(grep -c 'CFGEOF' "$SCRIPT" || true)" "0"
ck "bootstrap generates config via octocode config" "$(grepq 'octocode config --model "$LLM"' "$SCRIPT" && echo yes || echo no)" "yes"
# Model cache pinned INSIDE the home so the base image keeps carrying it.
ck "producer keeps the fastembed cache inside the home" "$(grepq 'XDG_CACHE_HOME="$OCTO_HOME/fastembed"' "$SCRIPT" && echo yes || echo no)" "yes"
ck "consumers point XDG_CACHE_HOME at the restored cache (both env blocks)" "$(grep -c 'XDG_CACHE_HOME *= *"${oct.db_path}/fastembed"' "$NIX" || true)" "2"
ck "graphrag phase runs the LLM-edge guard before checkpointing" \
   "$(grepq 'if [ "$USE_LLM" = "true" ]; then assert_llm_graph "$d" "$r" || exit 1; fi' "$SCRIPT" && echo yes || echo no)" "yes"

# ── 3) assert_llm_graph, executed with a stubbed octocode ────────────────────
awk '/^assert_llm_graph\(\) \{/ { f=1 } f { print } f && /^\}$/ { exit }' "$SCRIPT" > "$T/fn.sh"
ck "guard function extracted"  "$(grep -c 'assert_llm_graph() {' "$T/fn.sh")" "1"
run_guard() { # $1 = overview text file → prints rc
  ( . "$T/fn.sh"; octocode() { cat "$1_ov" 2>/dev/null || cat "$T/ov"; }; rc=0; assert_llm_graph "$T" testrepo >"$T/out" 2>&1 || rc=$?; echo "$rc" )
}
mkov() { # $1 = nodes  $2.. = "type count" lines
  _n=$1; shift
  { echo "Loading $_n GraphRAG nodes from database..."; echo "GraphRAG Knowledge Graph Overview"; echo "================================="; echo
    echo "The knowledge graph contains $_n nodes and 99 relationships."; echo; echo "Node Types:"; echo "  - source_file: $_n nodes"; echo; echo "Relationship Types:"
    for l in "$@"; do echo "  - ${l%% *}: ${l#* } relationships"; done; } > "$T/ov"
}
mkov 1155 "sibling_module 61" "imports 48"
ck "structural-only graph on a big repo is refused (rc 1)" "$(run_guard)" "1"
ck "...and the error names the types it saw" "$(grep -c 'types present: sibling_module imports' "$T/out")" "1"
mkov 1155 "sibling_module 61" "imports 48" "architectural_dependency 12" "uses 3"
ck "an LLM-derived type passes (rc 0)" "$(run_guard)" "0"
mkov 17 "sibling_module 16"
ck "a 17-node corpus with no LLM type is accepted (rc 0)" "$(run_guard)" "0"
ck "...and says so instead of staying silent" "$(grep -c 'small corpus, accepted' "$T/out")" "1"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
