#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-cgc-verify-surfaces.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Acceptance test for the two cloud-cgc MCP surfaces.
#
# The public/private split is NOT a tool subset -- both surfaces run the same
# image and expose the same tools. The split IS the LanceDB volume each one is
# pointed at, so the only way to know it holds is to ask each surface for the
# private repos and check what comes back. That is what this does.
#
# Endpoints, ports and the repo lists all come from build.json; nothing here
# hardcodes an IP, a port or a repo name. The probes run ON the box because
# both surfaces are mesh-only and the private one has no vhost at all -- but
# NOT against 127.0.0.1: they bind the WireGuard address specifically, so
# loopback is refused. The address comes from `ssh -G`, i.e. the same config
# the ssh above resolves, so there is still no IP written down here.
#
#   sh 1_cicd/src/ops/cloud-cgc-verify-surfaces.sh
#
# Exit 0 only if every assertion holds.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${BJ:-$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::build.json not found at $BJ"; exit 1; }

HOST=$(jq -r '.db_publish.host' "$BJ")
PUB_PORT=$(jq -r '.containers.app.port' "$BJ")
PVT_PORT=$(jq -r '.containers.pvt.port' "$BJ")
PUB_CTR=$(jq -r '.containers.app.container_name' "$BJ")
PVT_CTR=$(jq -r '.containers.pvt.container_name' "$BJ")
PRIV_REPOS=$(jq -r '.runtime.octocode.private_repos[]' "$BJ")
# First repo that is indexed but NOT private: the control case that must be
# present on BOTH surfaces. Derived, so adding repos never dates this script.
PUB_REPO=$(jq -r '
  .runtime.octocode as $o
  | ($o.private_repos // []) as $p
  | ($o.index_repos // []) | map(select(. as $r | $p | index($r) | not)) | .[0]
' "$BJ")

[ -n "$PUB_REPO" ] && [ "$PUB_REPO" != "null" ] || { echo "::error::no public repo in index_repos"; exit 1; }
# The surfaces listen on the mesh address only, so the probe has to name it.
# ssh -G reports what ssh itself would dial, which keeps this in step with the
# ssh config instead of duplicating an IP that would rot.
ADDR=$(ssh -G "$HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')
[ -n "$ADDR" ] || ADDR="$HOST"
echo "host=$HOST ($ADDR)  pub=:$PUB_PORT ($PUB_CTR)  pvt=:$PVT_PORT ($PVT_CTR)"
echo "public control repo=$PUB_REPO   private repos=$(echo $PRIV_REPOS | tr '\n' ' ')"
echo

# ---------------------------------------------------------------- remote probe
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
cat > "$TMP/probe.sh" <<'PROBE'
# MCP streamable-HTTP probe, run ON the box. $1=host $2=port $3=tool $4=args-json
# Prints exactly one classified line-block:
#   OK:<text>    a real tool result
#   ERR:<msg>    a JSON-RPC error, an octocode error inside a "successful" result,
#                or an unparseable/empty body
# The classification is the whole point. An earlier version of this script
# grepped the raw JSON for "No results found" and treated everything else as a
# hit -- so "Octocode error: Permission denied" scored as DATA, and an entirely
# empty private volume reported as a healthy private surface. A test that
# passes on errors is worse than no test.
U="http://$1:$2/mcp"; T="$3"; A="$4"
CT='-H Content-Type:application/json'
AC='-H Accept:application/json,text/event-stream'
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}'
SID=$(curl -sS -m 25 -D- -o /dev/null $CT $AC -d "$INIT" "$U" | awk 'tolower($1)=="mcp-session-id:"{gsub(/\r/,"");print $2}')
S=""; [ -n "$SID" ] && S="-H mcp-session-id:$SID"
curl -sS -m 25 $CT $AC $S -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$U" >/dev/null 2>&1
printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$T" "$A" > "$TMPREQ"
curl -sS -m 300 $CT $AC $S -d @"$TMPREQ" "$U" 2>/dev/null \
  | sed 's/^data: //' | grep -v '^event:' | grep -v '^$' \
  | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print("ERR:empty response (surface unreachable or container down)"); sys.exit()
try:
    d = json.loads(raw)
except Exception:
    print("ERR:unparseable response: " + raw[:200]); sys.exit()
if "error" in d:
    print("ERR:jsonrpc " + json.dumps(d["error"])[:300]); sys.exit()
r = d.get("result", {})
txt = "\n".join(c.get("text", "") for c in r.get("content", []) if isinstance(c, dict))
if r.get("isError"):
    print("ERR:" + txt[:400]); sys.exit()
# octocode reports its own failures inside a non-error result, so they have to
# be caught by content, not by status.
low = txt.lower()
for m in ("octocode error", "permission denied", "os error", "panicked", "no such file or directory"):
    if m in low:
        print("ERR:" + txt.strip()[:400]); sys.exit()
print("OK:" + txt)
'
PROBE

FAIL=0
# Never lets a failed probe abort the run: an unreachable surface is a result
# this script has to REPORT, not a reason to exit before saying which surface
# it was. Hence the `|| true` -- with set -e, a non-zero ssh inside a command
# substitution ends the script silently, which is the least useful possible
# outcome for a test whose whole job is to tell you what is broken.
call() { # call <port> <tool> <args-json>  -> response body on stdout
  ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no "$HOST" \
    "TMPREQ=\$(mktemp) sh -s $ADDR $1 '$2' '$3'" < "$TMP/probe.sh" 2>/dev/null || true
}
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

# A surface "has" a repo when a semantic search over it returns something other
# than the server's own empty-result sentence. Matching the sentence rather than
# guessing at hit counts keeps this honest when the corpus changes.
# Every assertion below reads a classified probe line, so "did it error" is a
# separate question from "did it find anything" -- which is exactly the
# distinction the first version of this script failed to make.
is_err()  { case "$1" in ERR:*) return 0 ;; *) return 1 ;; esac; }
body()    { printf '%s' "${1#OK:}"; }
# A surface "has" a repo when a semantic search over it returns something other
# than the server's own empty-result sentence. Matching that sentence rather
# than guessing at hit counts keeps this honest when the corpus changes.
has_hits() {
  is_err "$1" && return 1
  case "$1" in *"No results found"*) return 1 ;; esac
  [ -n "$(body "$1")" ]
}
graph_empty() {
  is_err "$1" && return 1
  case "$1" in *"knowledge graph is empty"*|*"GraphRAG knowledge graph is empty"*) return 0 ;; esac
  return 1
}
# Structural-only graphs are what the semantic phase leaves behind: nodes joined
# purely by sibling_module. Enrichment means the LLM pass added real relationship
# types, so the Relationship Types section -- not a node count -- is what gets
# asserted. Parsed from the decoded text, because the types live on their own
# lines and a raw-JSON scan cannot tell that section from the node-type one.
is_enriched() {
  is_err "$1" && return 1
  body "$1" | awk '
    /Relationship Types:/ { inrel = 1; next }
    inrel && /^[[:space:]]*-[[:space:]]*[A-Za-z_]+:/ {
      name = $0
      sub(/^[^-]*-[[:space:]]*/, "", name)
      sub(/:.*$/, "", name)
      if (name != "sibling_module") found = 1
    }
    END { exit(found ? 0 : 1) }'
}
rel_summary() {
  body "$1" | awk '/Relationship Types:/{inrel=1;next} inrel && NF {printf "%s ", $0} END{print ""}' | cut -c1-80
}

check_surface() { # check_surface <label> <port> <expect_private: yes|no>
  LBL=$1; PORT=$2; EXPECT=$3
  echo "== $LBL surface (:$PORT) — private repos expected: $EXPECT"

  R=$(call "$PORT" 'cgc.octocode.search' "{\"query\":\"docker compose service\",\"repo\":\"$PUB_REPO\"}")
  if is_err "$R";   then bad "$LBL: search '$PUB_REPO' errored — ${R#ERR:}"
  elif has_hits "$R"; then ok "$LBL: search '$PUB_REPO' returns hits (control)"
  else                   bad "$LBL: search '$PUB_REPO' found nothing — this surface has no semantic data"; fi

  G=$(call "$PORT" 'cgc.octocode.graphrag' "{\"operation\":\"overview\",\"repo\":\"$PUB_REPO\"}")
  if is_err "$G";      then bad "$LBL: graphrag '$PUB_REPO' errored — ${G#ERR:}"
  elif is_enriched "$G"; then ok "$LBL: graphrag '$PUB_REPO' enriched [$(rel_summary "$G")]"
  else                      bad "$LBL: graphrag '$PUB_REPO' structural-only or empty [$(rel_summary "$G")]"; fi

  for r in $PRIV_REPOS; do
    R=$(call "$PORT" 'cgc.octocode.search'   "{\"query\":\"token secret credential\",\"repo\":\"$r\"}")
    G=$(call "$PORT" 'cgc.octocode.graphrag' "{\"operation\":\"overview\",\"repo\":\"$r\"}")
    if [ "$EXPECT" = "yes" ]; then
      if is_err "$R";     then bad "$LBL: search '$r' errored — ${R#ERR:}"
      elif has_hits "$R"; then ok  "$LBL: search '$r' returns hits"
      else                     bad "$LBL: private repo '$r' is missing from the private volume"; fi
      if is_err "$G";        then bad "$LBL: graphrag '$r' errored — ${G#ERR:}"
      elif graph_empty "$G"; then bad "$LBL: graphrag '$r' is empty on the private surface"
      elif is_enriched "$G"; then ok  "$LBL: graphrag '$r' enriched [$(rel_summary "$G")]"
      else                        bad "$LBL: graphrag '$r' structural-only [$(rel_summary "$G")]"; fi
    else
      # An error is NOT an isolation pass. The public surface must answer, and
      # answer with nothing -- a broken endpoint proves neither.
      if is_err "$R";     then bad "$LBL: search '$r' errored, isolation unproven — ${R#ERR:}"
      elif has_hits "$R"; then bad "$LBL: PRIVATE REPO '$r' IS SEARCHABLE ON THE PUBLIC SURFACE"
      else                     ok  "$LBL: search '$r' correctly returns nothing"; fi
      if is_err "$G";        then bad "$LBL: graphrag '$r' errored, isolation unproven — ${G#ERR:}"
      elif graph_empty "$G"; then ok  "$LBL: graphrag '$r' correctly empty"
      else                        bad "$LBL: PRIVATE REPO '$r' HAS A GRAPH ON THE PUBLIC SURFACE"; fi
    fi
  done
  echo
}

check_surface pub "$PUB_PORT" no
check_surface pvt "$PVT_PORT" yes

if [ "$FAIL" = "0" ]; then
  echo "PASS — both surfaces serve semantic + graphrag, and the private repos are on the private one only"
  exit 0
fi
echo "::error::[cgc-verify] $FAIL assertion(s) failed"
exit 1
