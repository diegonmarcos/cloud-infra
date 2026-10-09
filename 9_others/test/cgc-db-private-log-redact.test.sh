#!/bin/sh
# Regression test: a PRIVATE repo's file paths and content must not reach the
# public Actions log of the cgc-db index jobs.
#
# The workflow runs in a public repository, so its logs are public. Run
# 37843203892 (job 113811440672, cloud-data-my-ai-memory, graphrag) printed lines
# such as "Updated description for: <private dir>/<file>.json"
# and export strings, through octo_log_digest's replay of octocode's last lines.
# This EXECUTES the real functions extracted from cloud-cgc-db-update.sh on a log
# shaped like that one, then checks the call sites and the fail-safe.
set -eu
ROOT=$(_d=$(cd "$(dirname "$0")" && pwd); while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d=$(dirname "$_d"); done; printf '%s' "$_d")
SCRIPT="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

for fn in octo_log_digest cgc_repo_is_private octo_log_redact octo_log_report; do
  awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" { p=1 } p { print } p && /^\}$/ { exit }' "$SCRIPT" >> "$T/fn.sh"
  ck "function $fn extracted" "$(grep -c "^$fn() {" "$T/fn.sh")" "1"
done
. "$T/fn.sh"

BJ="$T/build.json"
printf '%s\n' '{"runtime":{"octocode":{"private_repos":["secret-repo"]}}}' > "$BJ"

esc=$(printf '\033'); cr=$(printf '\r')
{
  printf '%s\n' "✓ Git repository detected: /repos/secret-repo"
  printf '%s\n' "📊 Loaded metadata for 189 files from database"
  printf '%s[K⠋ Indexing: 1/75 files (1%%)%s' "$esc" "$cr"
  printf '%s\n' "📝 Using simple description for: p-notes/proj/alpha-notes.md (AI criteria not met)"
  printf '%s\n' "📦 Found 0 imports, 3 exports in p-notes/proj/alpha-notes.md"
  printf '%s\n' '  Exports: ["alpha-notes — 0 open / 1 total", "Open", "Done"]'
  printf '%s\n' "🔄 Updating 8 nodes with AI-generated descriptions"
  printf '%s\n' "✅ Updated description for: p-notes/items/0001/919.json"
  printf '%s\n' "⚠️  Fallback to simple description for: p-notes/summary.md"
  printf '%s\n' "➕ Added new node: p-notes/proj/beta-notes.md"
  printf '%s\n' "Warning: AI architectural analysis failed: could not parse a_secret/dir/file.ts"
  printf '%s\n' "Error: failed to read /repos/secret-repo/x.json"
  printf '%s\n' "Info: AI analyzing 74 files for architectural relationships"
  printf '%s\n' "✅ Indexed 8 commits"
  printf '%s[K⠙ Indexing: 75/75 files (100%%)%s' "$esc" "$cr"
  printf '%s\n' "✓ Indexing complete! 75 of 75 files processed, GraphRAG: 82 blocks"
} > "$T/octo.log"

octo_log_report "$T/octo.log" 60 secret-repo > "$T/priv.out"
ck "private: no path separator survives"   "$(grep -c '/' "$T/priv.out" | tr -d ' ' | sed 's/^[1-9].*/leak/')" "$(grep -c 'Indexing: [0-9]*/[0-9]* files' "$T/priv.out" | tr -d ' ' | sed 's/^[1-9].*/leak/')"
ck "private: no .md/.json/.ts name"        "$(grep -cE '\.(md|json|ts)\b' "$T/priv.out" || true)" "0"
ck "private: no private dir name"            "$(grep -c 'p-notes' "$T/priv.out" || true)" "0"
ck "private: no export content"            "$(grep -c 'alpha-notes' "$T/priv.out" || true)" "0"
ck "private: completion count kept"        "$(grep -c '^✓ Indexing complete! 75 of 75 files processed, GraphRAG: 82 blocks$' "$T/priv.out")" "1"
ck "private: progress kept"                "$(grep -c '^\[cgc-db\] last octocode progress: Indexing: 75/75 files (100%)$' "$T/priv.out")" "1"
ck "private: LLM warning class kept"       "$(grep -c '^Warning: AI architectural analysis failed \[detail withheld' "$T/priv.out")" "1"
ck "private: path-shaped error withheld"   "$(grep -c '^Error: \[withheld: private repo\]$' "$T/priv.out")" "1"
ck "private: withheld count reported"      "$(grep -c 'line(s) withheld from this public log' "$T/priv.out")" "1"

octo_log_report "$T/octo.log" 60 public-repo > "$T/pub.out"
octo_log_digest "$T/octo.log" 60 > "$T/plain.out"
ck "public: output is the plain digest"    "$(cmp -s "$T/pub.out" "$T/plain.out" && echo same || echo differs)" "same"

BJ="$T/missing.json"
octo_log_report "$T/octo.log" 60 public-repo > "$T/failsafe.out"
ck "fail-safe: unreadable build.json redacts" "$(grep -c 'p-notes' "$T/failsafe.out" || true)" "0"
BJ="$T/build.json"
CGC_LOG_REDACT=1 octo_log_report "$T/octo.log" 60 public-repo > "$T/forced.out"
ck "CGC_LOG_REDACT=1 forces redaction"     "$(grep -c 'p-notes' "$T/forced.out" || true)" "0"

# Call sites: no octocode log may reach stdout without the private-aware wrapper.
ck "no bare octo_log_digest of an index log" "$(grep -cE '^[[:space:]]*octo_log_digest "\$_log"' "$SCRIPT" || true)" "0"
ck "three index-log call sites redact-aware" "$(grep -cE '^[[:space:]]*octo_log_report "\$_log" [0-9]+ "\$r"' "$SCRIPT")" "3"
ck "graphrag overview guarded"             "$(awk '/^assert_llm_graph\(\) \{/{p=1} p&&/cgc_repo_is_private "\$2"/{n++} p&&/^\}$/{exit} END{print n+0}' "$SCRIPT")" "1"
ck "smart-noindex dir list guarded"        "$(awk '/^smart_noindex\(\) \{/{p=1} p&&/cgc_repo_is_private/{n++} p&&/^\}$/{exit} END{print n+0}' "$SCRIPT")" "1"
ck "submodule exclusion guarded"           "$(awk '/^exclude_submodules\(\) \{/{p=1} p&&/cgc_repo_is_private/{n++} p&&/^\}$/{exit} END{print n+0}' "$SCRIPT")" "1"

echo "cgc-db-private-log-redact: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
