#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_detects_build_json.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ship.yml must treat a service's own build.json as a change to that service.
#
# The bug (2026-08-26, a57935adb): only a_solutions/<svc>/build.json changed (new
# base image + octocode fetch for cloud-cgc-pub-mcp). The push path filter did not
# match it and the detect step's pathspec ('a_solutions/*/src/**') mapped it to no
# service, so the run went green with Build/Deploy skipped and the consumer was
# never rebuilt. build.json drives docker.native_build -> Dockerfile.native and the
# compose file; it is as much "the service" as anything under src/.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  ck "$f: push path filter includes a_solutions/*/build.json" \
     "$(grep -c '^      - "a_solutions/\*/build.json"' "$Y" || true)" "1"
  ck "$f: detect pathspec includes a_solutions/*/build.json" \
     "$(grep -c "HEAD -- 'a_solutions/\*/src/\*\*' 'a_solutions/\*/build.json'" "$Y" || true)" "1"
done
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
