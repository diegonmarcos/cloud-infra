#!/bin/sh
# One service's failed build (or dist drift) must not block other services'
# deploys; the failed one is skipped, reported, and the run still ends red.
# Executes the real "Select services that built" step from ship.yml.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
py() { python3 -c "$1" "$2"; }
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  ck "$f: build ship step is non-fatal" "$(py 'import yaml,sys
j=yaml.safe_load(open(sys.argv[1]))["jobs"]["build"]["steps"]
print([s.get("continue-on-error") for s in j if s.get("id")=="ship"])' "$Y")" "[True]"
  ck "$f: build job still fails after trace upload" "$(py 'import yaml,sys
j=yaml.safe_load(open(sys.argv[1]))["jobs"]["build"]["steps"]
n=[s.get("name") for s in j]
print(n.index("Upload trace")<n.index("Fail build job if any service failed"))' "$Y")" "True"
  ck "$f: deploy runs despite failed build" "$(py 'import yaml,sys
i=yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]["if"]
print("!cancelled()" in i and "needs.build.result" not in i)' "$Y")" "True"
  ck "$f: deploy-gate still fails on build failure" "$(py 'import yaml,sys
r=[s["run"] for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["steps"] if "run" in s][0]
print("\"$BUILD_RESULT\" != \"success\"" in r)' "$Y")" "True"
  py 'import yaml,sys
for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]["steps"]:
    if s.get("id")=="built": print(s["run"])' "$Y" > "$T/step.sh"
  run() { # $1 changed, $2 trace json (empty = none)
    rm -f "$T/out" "$T/t.json"; : > "$T/out"
    [ -n "$2" ] && printf '%s' "$2" > "$T/t.json"
    VM=v CHANGED="$1" TRACE="$T/t.json" GITHUB_OUTPUT="$T/out" sh "$T/step.sh" >/dev/null 2>&1
    tr '\n' ' ' < "$T/out"; }
  TR='{"services":[{"dir":"a","status":"ok"},{"dir":"b","status":"fail"},{"dir":"c","status":"ok"},{"dir":"d","status":"skip"}]}'
  ck "$f: failed b skipped, a+c deploy" "$(run 'a b c' "$TR")" "dirs=a c go=true "
  ck "$f: empty CHANGED -> only ok services" "$(run '' "$TR")" "dirs=a c go=true "
  ck "$f: exact match (a != a2)" "$(run 'a2' "$TR")" "dirs= go=false "
  ck "$f: all failed -> no deploy" "$(run 'b' "$TR")" "dirs= go=false "
  ck "$f: no trace -> no deploy" "$(run 'a' '')" "go=false "
done
echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
