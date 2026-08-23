#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-llm-wiring.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
for k in openai_api_url ollama_api_url api_key health_url models; do
  v=$(jq -r ".runtime.octocode.llm.$k // empty" "$BJ")
  ck "build.json declares .runtime.octocode.llm.$k" "$([ -n "$v" ] && echo yes || echo no)" "yes"
done

# 2) the script must EXPORT them — a bare assignment is invisible to octocode.
grepq() { python3 -c "import sys;sys.exit(0 if sys.argv[1] in open(sys.argv[2],encoding='utf8').read() else 1)" "$1" "$2"; }
ck "script exports OPENAI_API_URL" \
   "$(grepq 'export OPENAI_API_URL' "$SCRIPT" && echo yes || echo no)" "yes"

# 3) the declared model prefix must match the env var the script exports:
#    octocode picks the provider from the model prefix (openai: -> OPENAI_API_URL).
M=$(jq -r '.runtime.octocode.update.llm_model' "$BJ")
case "$M" in
  openai:*) need=OPENAI_API_URL ;;
  ollama:*) need=OLLAMA_API_URL ;;
  *)        need=UNKNOWN ;;
esac
ck "llm_model '$M' maps to an exported var" \
   "$(grepq "export OPENAI_API_URL OLLAMA_API_URL" "$SCRIPT" && [ "$need" != UNKNOWN ] && echo yes || echo no)" "yes"

# 4) graphrag must PREFLIGHT and hard-fail, not warn. Without this the next
#    endpoint outage silently reproduces structural-only graphs.
ck "graphrag preflights the LLM endpoint" \
   "$(grepq 'LLM endpoint is unreachable' "$SCRIPT" && echo yes || echo no)" "yes"

# 5) no repo secret may gate this path — my-ai-api injects its own upstream key.
ck "no secrets.OPENROUTER_API_KEY gates the index job" \
   "$(python3 -c "
import sys
p=sys.argv[1]
live=[l for l in open(p,encoding='utf8') if 'OPENROUTER' in l and not l.lstrip().startswith('#')]
print('no' if live else 'yes')" "$ROOT/1_cicd/src/cicd/cgc-db-index.yml")" "yes"

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

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
