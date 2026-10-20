#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_src_hash_covers_all_source_ext.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# .src-hash input set must cover every JS/TS source extension that ships
# (regression: .mjs was missing, so my-ai-api Ship skipped real changes).
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
S="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-build-nix.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
# shellcheck disable=SC1090
eval "$(sed -n '/^src_hash_file_list() {/,/^}/p' "$S")"
mkdir -p "$T/s/lib" "$T/s/node_modules/x"
for f in a.ts b.tsx c.mts d.cts e.js f.jsx g.mjs h.cjs Dockerfile package.json lib/i.mjs lib/Dockerfile; do : > "$T/s/$f"; done
: > "$T/s/node_modules/x/z.mjs"; : > "$T/s/README.md"
# non-git fallback (find) path
want="Dockerfile
a.ts
b.tsx
c.mts
d.cts
e.js
f.jsx
g.mjs
h.cjs
lib/Dockerfile
lib/i.mjs
package.json"
ck "find path covers all source extensions, prunes node_modules" "$(src_hash_file_list "$T/s")" "$want"
# git path
git -C "$T/s" init -q; git -C "$T/s" add -A -f . >/dev/null 2>&1
git -C "$T/s" rm -rq --cached node_modules >/dev/null 2>&1 || true
ck "git path covers all source extensions" "$(src_hash_file_list "$T/s")" "$want"
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
