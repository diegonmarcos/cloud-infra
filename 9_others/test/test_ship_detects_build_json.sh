#!/bin/sh
# ship.yml must treat a service's own build.json as a change to that service.
#
# The bug (2026-08-26, a57935adb): only a_solutions/<svc>/build.json changed (new
# base image + octocode fetch for cloud-cgc-pub-mcp). Change detection mapped it to
# no service, so the run went green with Build/Deploy skipped and the consumer was
# never rebuilt (run 32952457089). build.json drives docker.native_build ->
# Dockerfile.native and the compose file; it is as much "the service" as src/.
#
# 2026-09-16 (#372) — REWRITTEN, and why matters more than what.
#
# The original version of this file grepped ship.yml for two literal strings: a
# `- "a_solutions/*/build.json"` entry in the push `paths:` filter, and a
# superproject `git diff HEAD -- 'a_solutions/*/src/**' 'a_solutions/*/build.json'`
# pathspec. Both belonged to an implementation that no longer exists. On
# 2026-09-06 a_solutions stopped being a submodule and became a separate
# repository (diegonmarcos/cloud-u-containers), and detection moved INSIDE that
# checkout. So this tester reported 4/4 red against a tree whose behaviour was
# correct, and it would have gone green again for anyone who pasted the two
# strings back in WITHOUT restoring the behaviour — including a `paths:` entry
# that can never match anything, because a_solutions is not tracked in this
# repository at all.
#
# A guard that asserts the text of one implementation is worthless across the
# refactor it is supposed to survive. This version asserts the CONTRACT and
# derives everything it can: it extracts the live classifier out of ship.yml and
# runs it, against real service names read from a_solutions/*/build.json.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── Subject reachability. A check that cannot reach its subject FAILS. ──
# Service names are DERIVED from a_solutions/*/build.json rather than restated
# here, so this tester cannot drift from the directory it is about. That also
# means it is worthless without the checkout, and must say so instead of
# quietly asserting nothing.
SVC=""
for bj in "$REPO_ROOT"/a_solutions/*/build.json; do
  [ -f "$bj" ] || continue
  SVC="$(basename "$(dirname "$bj")")"
  break
done
[ -n "$SVC" ] || {
  echo "::error::no a_solutions/*/build.json found — the cloud-u-containers checkout is missing, so ship.yml's build.json detection was NOT verified."
  exit 1; }
echo "── sample service derived from a_solutions/: $SVC ──"

for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  [ -f "$Y" ] || { echo "::error::$f missing"; fail=$((fail+1)); continue; }

  # 1. The ONLY route a container change reaches this workflow by, since the
  #    2026-09-06 split. Without it, nothing below can ever run.
  ck "$f: subscribes to repository_dispatch containers-push" \
     "$(grep -c 'types: \[containers-push\]' "$Y" || true)" "1"

  # 2. The push `paths:` filter must NOT name a_solutions. This is an
  #    anti-regression, not an oversight: a_solutions is a separate repository,
  #    nothing in it touches this one, and a `paths:` entry for it would be
  #    permanently dead configuration that reads as coverage. The previous
  #    version of this tester demanded exactly that entry.
  ck "$f: push paths filter does NOT name a_solutions (it cannot match; separate repo)" \
     "$(sed -n '/^on:/,/^jobs:/p' "$Y" | grep -c '^      - "a_solutions/' || true)" "0"

  # 3. The contract itself. Extract the live classifier expression out of the
  #    workflow and EXECUTE it — never restate it here, or this file becomes
  #    the second copy that has to be remembered.
  RE="$(sed -n 's/.*CHANGED_DIRS=\$(printf .*grep -E '"'"'\([^'"'"']*\)'"'"'.*/\1/p' "$Y" | head -1)"
  if [ -z "$RE" ]; then
    echo "  FAIL $f: could not extract the CHANGED_DIRS classifier regex from the workflow"
    fail=$((fail+1)); continue
  fi
  echo "  ·    $f classifier: $RE"
  classify() { printf '%s\n' "$1" | grep -E "$RE" | awk -F/ '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

  ck "$f: a build.json-only change maps to its service" \
     "$(classify "$SVC/build.json")" "$SVC"
  ck "$f: a src/ change still maps to its service" \
     "$(classify "$SVC/src/code/Dockerfile")" "$SVC"
  ck "$f: an unrelated top-level file maps to nothing" \
     "$(classify "$SVC/README.md")" ""
done

# ── #451: a _shared/ change is a dependency fan-out, not a first-segment map ──
# `_shared/engine.nix` matches neither branch of the classifier, so it must be
# forwarded to the engine-consumer reverse-walk, which derives the consumer set
# from each service's src declaration (`import ../../_shared/engine.nix`). Two
# things are asserted: the wiring is present in the detect step, and the walk
# resolves the real engine consumers over THIS checkout (proving the mapping is
# declaration-derived, never a hardcoded list that can drift).
ENG_SCRIPT="cloud-ship-detect-engine-consumers.sh"
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  [ -f "$Y" ] || { echo "::error::$f missing"; fail=$((fail+1)); continue; }
  ck "$f: detect step forwards _shared/ to the engine-consumer walk" \
     "$(grep -c "$ENG_SCRIPT" "$Y" || true)" "1"
done
ENG_SRC="$REPO_ROOT/1_cicd/src/scripts/$ENG_SCRIPT"
if [ -f "$ENG_SRC" ]; then
  ENG_RES=$(printf '%s\n' '_shared/engine.nix' | bash "$ENG_SRC" 2>/dev/null || true)
  ENG_RES="${ENG_RES% }"
  if [ -z "$ENG_RES" ]; then
    echo "  FAIL engine-consumer walk resolved NOTHING for _shared/engine.nix over the real checkout"
    fail=$((fail+1))
  else
    echo "  ok   engine-consumer walk resolved $(printf '%s' "$ENG_RES" | wc -w | tr -d ' ') service(s) for _shared/engine.nix"
    # Every resolved name must be a real service dir — a derived mapping that
    # names a directory that is not there would silently fail to ship.
    for _svc in $ENG_RES; do
      if [ -d "$REPO_ROOT/a_solutions/$_svc/src" ]; then
        echo "  ok   resolved consumer $_svc → real service dir"
      else
        echo "  FAIL resolved consumer $_svc has no a_solutions/$_svc/src"
        fail=$((fail+1))
      fi
    done
  fi
else
  echo "  FAIL $ENG_SCRIPT missing — the engine fan-out has no implementation"
  fail=$((fail+1))
fi

# ── #564: the exact dispatch ranges of the two runs reported as "detection dead" ──
# Ship 35992310672 (a_solutions 7048de16..e2ec667f: _shared/engine.nix, both
# kg-store build.json+compose.nix, my-ai-api build.json) and 35992663222
# (e2ec667f..d1a612e1). The changed-file set is READ from cloud-u-containers
# history, not restated, and run through the live classifier + engine walk.
# 35992310672 resolved a real ship (4 VMs) and died at Build → oci-apps on a
# #542-renamed build-*.json; 35992663222's range touched only .github/, so its
# verdict=empty was correct. Both facts are pinned here so the next "nothing
# deploys" starts from the right layer.
Y="$REPO_ROOT/1_cicd/src/cicd/ship.yml"
RE="$(sed -n 's/.*CHANGED_DIRS=\$(printf .*grep -E '"'"'\([^'"'"']*\)'"'"'.*/\1/p' "$Y" | head -1)"
resolve() {
  _set="$(git -C "$REPO_ROOT/a_solutions" diff --name-only "$1" "$2" 2>/dev/null)" || return 1
  [ -n "$_set" ] || { echo "__EMPTYDIFF__"; return 0; }
  { printf '%s\n' "$_set" | grep -E "$RE" | awk -F/ '{print $1}'
    printf '%s\n' "$_set" | bash "$ENG_SRC" 2>/dev/null | tr ' ' '\n'; } | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
if git -C "$REPO_ROOT/a_solutions" cat-file -e 'd1a612e1d46439df2f0309bfdd7df4f1bc6bf361^{commit}' 2>/dev/null; then
  R1="$(resolve 7048de166e8ce49651b8054c34248b5619668633 e2ec667ff16f075435772961557df5377c44e191)"
  for _svc in user-ai_kg-store user-ai_kg-store-pub user-ai_my-ai-api; do
    ck "run 35992310672 range resolves $_svc" "$(printf ' %s ' "$R1" | grep -c " $_svc " || true)" "1"
  done
  ck "run 35992310672 range fans _shared/ out to >10 engine consumers" \
     "$([ "$(printf '%s' "$R1" | wc -w)" -gt 10 ] && echo yes || echo no)" "yes"
  ck "run 35992663222 range (.github/ only) resolves to NO service — verdict=empty was honest" \
     "$(resolve e2ec667ff16f075435772961557df5377c44e191 d1a612e1d46439df2f0309bfdd7df4f1bc6bf361)" ""
else
  echo "  FAIL a_solutions history lacks d1a612e1 — the #564 ranges were NOT verified (needs fetch-depth: 0)"
  fail=$((fail+1))
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
