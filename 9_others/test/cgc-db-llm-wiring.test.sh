#!/bin/sh
# Regression test for the GraphRAG LLM wiring in cloud-cgc-db-update.sh.
#
# The bug this guards: the graphrag phase rewrote config.toml's models to
# `openai:*` correctly, but nothing ever exported OPENAI_API_URL/OPENAI_API_KEY,
# so octocode logged "LLM client not initialized" as a WARNING, kept going, and
# shipped a DB whose only relationships were structural `sibling_module` edges.
# Exit code was 0. The run looked green. That silent degradation is the defect.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
BJ="$ROOT/1_cloud-configs/dist/build-cloud-cgc-pub-mcp.json"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# 1) build.json must declare every field the script jq-reads. A rename on either
#    side silently yields "" and re-arms the exact silent degradation above.
for k in openrouter_api_url openai_api_url ollama_api_url api_key health_url models; do
  v=$(jq -r ".runtime.octocode.llm.$k // empty" "$BJ")
  ck "build.json declares .runtime.octocode.llm.$k" "$([ -n "$v" ] && echo yes || echo no)" "yes"
done

# 2) the script must EXPORT them — a bare assignment is invisible to octocode.
grepq() { python3 -c "import sys;sys.exit(0 if sys.argv[1] in open(sys.argv[2],encoding='utf8').read() else 1)" "$1" "$2"; }
ck "script exports OPENROUTER_API_URL" \
   "$(grepq 'export OPENROUTER_API_URL' "$SCRIPT" && echo yes || echo no)" "yes"

# 3) the declared model prefix must match the env var the script exports:
#    octocode picks the provider from the model prefix (openai: -> OPENAI_API_URL).
M=$(jq -r '.runtime.octocode.update.llm_model' "$BJ")
case "$M" in
  openrouter:*) need=OPENROUTER_API_URL; field=openrouter_api_url ;;
  openai:*)     need=OPENAI_API_URL;     field=openai_api_url ;;
  ollama:*)     need=OLLAMA_API_URL;     field=ollama_api_url ;;
  *)            need=UNKNOWN;            field=UNKNOWN ;;
esac
ck "llm_model '$M' maps to an exported var" \
   "$(python3 -c "
import sys
need = sys.argv[1]
if need == 'UNKNOWN':
    print('no'); sys.exit()
# a bare assignment is invisible to octocode, and the var has to be a WORD on the
# export line -- a substring match would pass on OPENROUTER_API_URL for OPENAI_API_URL.
print('yes' if any(l.startswith('export ') and need in l.split()
                   for l in open(sys.argv[2], encoding='utf8')) else 'no')" "$need" "$SCRIPT")" "yes"

# the preflight has to test the url THAT prefix resolves to. Checking a fixed var
# green-lights a model routed elsewhere -- the one config it exists to reject.
ck "preflight resolves $field for '$M'" \
   "$(grepq "_llm_field=\"$field\"" "$SCRIPT" && echo yes || echo no)" "yes"

# octocode POSTs to this url verbatim. Against the bare /v1 base it builds a
# client and then gets an empty body back ("Failed to parse JSON from response"),
# which degrades to a structural-only graph exactly like having no client --
# both forms verified live. The full completions path is not cosmetic.
U=$(jq -r ".runtime.octocode.llm.$field // empty" "$BJ")
ck "$field is the full completions path" \
   "$(case "$U" in */chat/completions) echo yes ;; *) echo no ;; esac)" "yes"

# 4) graphrag must PREFLIGHT and hard-fail, not warn. Without this the next
#    endpoint outage silently reproduces structural-only graphs.
ck "graphrag preflights the LLM endpoint" \
   "$(grepq 'refusing to ship a structural-only graph' "$SCRIPT" && echo yes || echo no)" "yes"

# 5) CI goes DIRECT to openrouter.ai with the real repo secret (user decision
#    2026-08-23) — that is what freed the matrix from the single WireGuard peer
#    slot and let graphrag fan out 8-wide. An earlier version of this test
#    asserted the OPPOSITE (no repo secret, relay injects the key); the relay
#    remains the declared build.json fallback for local/dagu runs only.
_yml="$ROOT/1_cicd/src/cicd/cgc-db-index.yml"
ck "index job passes secrets.OPENROUTER_API_KEY to the env" \
   "$(python3 -c "
import sys
live=[l for l in open(sys.argv[1],encoding='utf8')
      if 'secrets.OPENROUTER_API_KEY' in l and not l.lstrip().startswith('#')]
print('yes' if live else 'no')" "$_yml")" "yes"
ck "index job env URL is the full completions path" \
   "$(python3 -c "
import sys
live=[l for l in open(sys.argv[1],encoding='utf8')
      if l.lstrip().startswith('OPENROUTER_API_URL:') and '/chat/completions' in l]
print('yes' if live else 'no')" "$_yml")" "yes"
# restore-all legitimately keeps its WireGuard step (one job, ssh propagation
# to the box, no slot contention) — only the fan-out MATRIX must be mesh-free,
# so the assertion is scoped to the region before restore-all.
ck "index matrix no longer crosses the mesh (no WireGuard step)" \
   "$(python3 -c "
import sys
s=open(sys.argv[1],encoding='utf8').read()
matrix=s[:s.index('restore-all:')]
print('no' if 'cloud-ship-ci-setup-wireguard' in matrix else 'yes')" "$_yml")" "yes"

# 6) the force path must be wired end to end, or a fixed indexer silently
#    re-skips every repo whose HEAD did not move. Three links, all breakable
#    independently: dispatch input -> reusable-workflow input -> script env.
ck "orchestrator passes force through to both phases" \
   "$(python3 -c "
print(open('$ROOT/.github/workflows/cgc-db.yml',encoding='utf8').read().count('github.event.inputs.force'))")" "2"
ck "index workflow maps force -> CGC_FORCE" \
   "$(grepq 'CGC_FORCE:' "$ROOT/.github/workflows/cgc-db-index.yml" && echo yes || echo no)" "yes"
ck "script honours CGC_FORCE at the change gate" \
   "$(grepq 'CGC_FORCE:-0' "$SCRIPT" && echo yes || echo no)" "yes"

# 7) octocode picks its PROVIDER from the model-string prefix, and it reads the
#    key/url env pair that prefix names. A hardcoded `openrouter:` in the emitted
#    config sends it hunting for OPENROUTER_API_KEY, which nothing sets -- it
#    then logs "LLM client not initialized" and quietly falls back to a
#    structural-only graph. That degraded a whole run undetected. Comment lines
#    are excluded: the fix is documented in prose right where it was made.
ck "no hardcoded model literal survives in the emitted config" \
   "$(python3 -c "
import re, sys
pat = re.compile(r'[\"\']((openai|ollama|openrouter):[\\w.-]+/[\\w.-]+)[\"\']')
print(sum(bool(pat.search(l)) for l in open(sys.argv[1],encoding='utf8')
          if not l.lstrip().startswith('#')))" "$SCRIPT")" "0"

# [llm] model is the field the architectural-analysis pass reads. The graphrag
# rewrite only ever touched description_model/relationship_model, so a config
# inherited from an existing image kept its stale provider there forever.
ck "config rewrite corrects [llm] model too" \
   "$(python3 -c "
import sys
s=open(sys.argv[1],encoding='utf8').read()
print('yes' if 'in_llm && /^[[:space:]]*model[[:space:]]*=/' in s else 'no')" "$SCRIPT")" "yes"

# 8) force must invalidate the GRAPH without touching the EMBEDDINGS. octocode
#    rebuilds the graph only when it finds none, so a structural-only graph left
#    in place makes the repair a no-op; dropping code_blocks instead would turn a
#    ~2h repair into a ~12h from-scratch rebuild.
ck "force drops the graphrag tables" \
   "$(python3 -c "
import sys
s=open(sys.argv[1],encoding='utf8').read()
print('yes' if all(t in s for t in ('graphrag_nodes.lance','graphrag_relationships.lance','graphrag_git_metadata.lance')) else 'no')" "$SCRIPT")" "yes"

ck "force never drops the embeddings" \
   "$(python3 -c "
import sys
# any rm/purge line naming code_blocks would be the ~12h regression
print(sum('code_blocks' in l and 'rm ' in l for l in open(sys.argv[1],encoding='utf8')))" "$SCRIPT")" "0"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
