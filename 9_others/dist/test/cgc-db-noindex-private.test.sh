#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-noindex-private.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Ticket #360 — a file whose NAME declares it private must never reach the code
# graph index, on either surface.
#
# Background: a plain cgc.octocode.search against cloud-cgc-pub-mcp returned
# aa_cloud-superapp/data/services_private.json — 602 lines enumerating every
# internal host:port pair and which auth component fronts what. No credentials,
# but a complete target map, and the pub surface answers ANONYMOUSLY off-mesh
# (verified 2026-09-16: HTTP 200 + tools/list from 129.151.228.66 with the
# Authorization header stripped, while c3-infra-mcp 403s over the same socket).
#
# The rule is a NAMING CONVENTION in build.json .runtime.octocode.noindex_patterns,
# not a path blocklist, so the NEXT such file is excluded the day it is written.
#
# This test does not merely grep for the pattern in the JSON — a pattern that is
# present but does not actually match the file is exactly the fail-green this
# repo keeps getting bitten by. It replays the patterns through git's own
# gitignore engine (the syntax octocode's .noindex uses) against real paths.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# a_solutions IS cloud-u-containers: lint-pipeline.yml checks it out to that path,
# a dev box has it as a sibling clone. Try both, fail loudly if neither — never
# skip, because a test that silently does nothing reports the same green as a pass.
for c in "$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json" \
         "$ROOT/../cloud-u-containers/user-ai_cloud-cgc-pub-mcp/build.json"; do
  [ -f "$c" ] && { BJ=$c; break; }
done
[ -n "${BJ:-}" ] || { echo "FATAL: cloud-cgc-pub-mcp build.json not found (looked in a_solutions/ and ../cloud-u-containers/)"; exit 1; }
SCRIPT="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── 1) the rule is declared, and declared as a convention ───────────────────
has() { jq -e --arg p "$1" '.runtime.octocode.noindex_patterns | index($p)' "$BJ" >/dev/null 2>&1 && echo yes || echo no; }
ck "*_private.json is declared"  "$(has '*_private.json')"  "yes"
ck "*_private.yaml is declared"  "$(has '*_private.yaml')"  "yes"
ck "*_private.yml is declared"   "$(has '*_private.yml')"   "yes"
# A bare path would fix this one file and nothing else — that is the recurrence
# the ticket asked to close.
ck "the rule is a glob, not the offending path" \
   "$(jq -r '.runtime.octocode.noindex_patterns | map(select(test("services_private"))) | length' "$BJ")" "0"

# ── 2) the patterns actually reach the indexer ──────────────────────────────
grepq() { python3 -c "import sys;sys.exit(0 if sys.argv[1] in open(sys.argv[2],encoding='utf8').read() else 1)" "$1" "$2"; }
ck "producer reads noindex_patterns from build.json" \
   "$(grepq ".runtime.octocode.noindex_patterns" "$SCRIPT" && echo yes || echo no)" "yes"
ck "producer writes them into the repo's .noindex" \
   "$(grepq 'printf '"'"'%s\n'"'"' "$NOINDEX_PATTERNS" > "$d/.noindex"' "$SCRIPT" && echo yes || echo no)" "yes"

# ── 3) BOTH surfaces are covered, by construction ───────────────────────────
# There is one .runtime.octocode block and one indexer pass. cloud-cgc-pvt-mcp is
# a container declared inside THIS build.json, so it cannot drift to a different
# noindex set. If someone ever splits pvt into its own build.json, this goes red
# and the rule has to be re-applied there deliberately.
ck "pvt is declared in the same build.json as the rule" \
   "$(jq -r '.containers.pvt.container_name // "ABSENT"' "$BJ")" "cloud-cgc-pvt-mcp"
ck "pub/pvt split is the volume, not a per-file rule" \
   "$(jq -r 'if (.runtime.octocode.db_volume != .runtime.octocode.pvt_db_volume) then "yes" else "no" end' "$BJ")" "yes"

# ── 4) THE REAL CHECK: replay the patterns through gitignore semantics ──────
# octocode honours a gitignore-syntax .noindex (cloud-cgc-db-update.sh:198). git is
# the reference implementation of that syntax, so ask git.
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
jq -r '.runtime.octocode.noindex_patterns[]' "$BJ" > "$REPO/.gitignore"

ignored() { # path -> yes/no, per git's own matcher
  git -C "$REPO" check-ignore -q -- "$1" && echo yes || echo no
}

# MUST be excluded — the offending file, plus the next one nobody has written yet.
ck "the reported file is excluded"        "$(ignored 'aa_cloud-superapp/data/services_private.json')" "yes"
ck "...at the repo root too"              "$(ignored 'services_private.json')"                        "yes"
ck "...at any nesting depth"              "$(ignored 'a/b/c/d/e/hosts_private.json')"                 "yes"
ck "a future *_private.yaml is excluded"  "$(ignored 'infra/topology_private.yaml')"                  "yes"
ck "a future *_private.yml is excluded"   "$(ignored 'infra/topology_private.yml')"                   "yes"

# MUST NOT be excluded — real source that merely has "private" in the name. These
# are the actual files the wider glob *_private.* would have silently deleted from
# the index, which is why the rule is scoped to data extensions.
ck "tool_private.ts stays indexed"        "$(ignored 'ac_cloud-chat/app/products/agents/actions/remote/tool_private.ts')"  "no"
ck "convert_private.tsx stays indexed"    "$(ignored 'ac_cloud-chat/app/screens/channel_settings/convert_private.tsx')"    "no"
ck "public_private.tsx stays indexed"     "$(ignored 'ac_cloud-chat/app/screens/channel_info/title/public_private/public_private.tsx')" "no"
ck "PrivateFolderManager.kt stays indexed" "$(ignored 'ac_cloud-media-center/app/src/main/kotlin/PrivateFolderManager.kt')" "no"
ck "an ordinary data file stays indexed"  "$(ignored 'aa_cloud-superapp/data/services.json')"          "no"
ck "'private' as a directory is not enough" "$(ignored 'app/private/index.ts')"                        "no"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
