#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_docker_hash_covers_build_json.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# step_docker's rebuild key must cover build.json's `docker` block, not only src/.
#
# The bug (2026-08-26, run 32952457089): a57935adb changed only
# docker.native_build (new base image + pinned octocode fetch) for
# cloud-cgc-pub-mcp. src/ was untouched, so the smart-hash matched the VM's
# .docker-src-hash, the rebuild was skipped, and the deploy shipped the stale
# image as a green run. For image-wrapper services the docker block IS the
# Dockerfile (Dockerfile.native is rendered from it).
#
# Executes the same canonicalisation the engine uses (node primary, python
# fallback) on a fixture and asserts both agree — a divergence would make the
# key flip between runners and force spurious rebuilds.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
S="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-build-docker.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

ck "docker block feeds the rebuild hash" "$(grep -c "printf 'build.json:docker %s" "$S" || true)" "1"
ck "hash still excludes compose.nix (runtime-only)" "$(grep -c "not -name 'compose.nix' -exec sha256sum" "$S" || true)" "1"

printf '%s' '{"docker":{"native_build":{"cmd":"a — b","apt":"x"},"image":"i","arch":"arm64"},"runtime":{"z":1}}' > "$T/build.json"
NODE=$(node -e "const s=v=>Array.isArray(v)?'['+v.map(s).join(',')+']':(v&&typeof v==='object')?'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+s(v[k])).join(',')+'}':JSON.stringify(v);const c=require('$T/build.json');process.stdout.write(s(c.docker||{}))" 2>/dev/null || echo NONODE)
PY=$(python3 -c "import json; print(json.dumps(json.load(open('$T/build.json')).get('docker',{}),sort_keys=True,separators=(',',':'),ensure_ascii=False),end='')" 2>/dev/null || echo NOPY)
if [ "$NODE" != "NONODE" ] && [ "$PY" != "NOPY" ]; then
  ck "node and python canonical forms agree (sorted keys, no spaces, raw unicode)" "$NODE" "$PY"
  ck "canonical form sorts keys and drops whitespace" "$PY" '{"arch":"arm64","image":"i","native_build":{"apt":"x","cmd":"a — b"}}'
else
  echo "  skip canonical-form parity (node or python3 unavailable)"
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
