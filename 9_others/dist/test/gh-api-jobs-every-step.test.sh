#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/gh-api-jobs-every-step.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Ticket #400. Guards 9_others/src/gh-api.sh — the tool the agent fleet uses to
# prove a continuous-integration run is green.
#
# The defect: `gh-api.sh jobs` printed only the steps whose conclusion was
# neither success nor skipped. A run where everything passed, a run whose every
# step was skipped (cloud-infra Ship 35069355373: nothing was built, run still
# concluded "success"), and a run the tool never reached at all (wrong run
# identifier — jq error on standard error, exit status zero) all rendered as the
# same empty listing. The one tool that proves continuous integration is green
# could not tell those three apart.
#
# Every assertion below EXECUTES the real script. The GitHub API is replaced by
# a stub curl placed first on PATH, which replays a fixture and a chosen HTTP
# status, so the whole matrix — success, skipped, empty, unauthorized, absent —
# is reproducible offline and identical on every machine.
set -u

ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
TOOL="$ROOT/9_others/src/gh-api.sh"
[ -f "$TOOL" ] || { echo "::error::gh-api.sh not found at $TOOL"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── the stub GitHub API ───────────────────────────────────────────────────────
# Replays $GH_API_STUB_BODY with HTTP status $GH_API_STUB_CODE, honouring the
# -w '\n%{http_code}' the tool asks for. It also records that it was called, so
# a case that must refuse BEFORE any network access can prove it did.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$GH_API_STUB_CALLS"
printf '%s' "$(cat "$GH_API_STUB_BODY")"
for _arg in "$@"; do
    [ "$_arg" = "-w" ] && { printf '\n%s' "${GH_API_STUB_CODE:-200}"; break; }
done
STUB_EOF
chmod +x "$T/bin/curl"
export GH_API_STUB_CALLS="$T/calls"
: > "$GH_API_STUB_CALLS"

# Two runs that were indistinguishable before this ticket: same jobs, same
# job-level conclusion, opposite realities at step level.
cat > "$T/all-success.json" <<'JSON_EOF'
{"jobs":[{"id":11,"name":"Build → oci-apps","conclusion":"success","steps":[
  {"number":1,"name":"Checkout","conclusion":"success"},
  {"number":2,"name":"Build image","conclusion":"success"},
  {"number":3,"name":"Push image","conclusion":"success"}]}]}
JSON_EOF
cat > "$T/all-skipped.json" <<'JSON_EOF'
{"jobs":[{"id":11,"name":"Build → oci-apps","conclusion":"success","steps":[
  {"number":1,"name":"Checkout","conclusion":"skipped"},
  {"number":2,"name":"Build image","conclusion":"skipped"},
  {"number":3,"name":"Push image","conclusion":"skipped"}]}]}
JSON_EOF
echo '{"jobs":[]}'                                  > "$T/no-jobs.json"
echo '{"jobs":[{"id":11,"name":"Build","conclusion":null,"status":"queued","steps":[]}]}' > "$T/no-steps.json"
echo '{"message":"Bad credentials"}'                > "$T/bad-credentials.json"
echo '{"message":"Not Found"}'                      > "$T/not-found.json"

run_jobs() { # run_jobs <fixture> <http_code> [token] -> writes $T/out, returns tool exit status
    GH_API_STUB_BODY="$T/$1" GH_API_STUB_CODE="$2" GH_TOKEN="${3-stub-token}" \
        PATH="$T/bin:$PATH" \
        "$TOOL" jobs diegonmarcos/cloud-infra 35069355373 >"$T/out" 2>&1
}

# ── 1) the defect itself: every step is listed, with its conclusion ──────────
run_jobs all-success.json 200; rc=$?
ck "all-success run exits 0"                          "$rc" "0"
ck "all-success run lists all three steps"            "$(grep -c '^    step ' "$T/out")" "3"
ck "step conclusions are printed, not filtered out"   "$(grep -c 'step 2 Build image => success' "$T/out")" "1"
cp "$T/out" "$T/out-success"

# ── 2) the incident: all-skipped must NOT read like all-success ─────────────
run_jobs all-skipped.json 200; rc=$?
ck "all-skipped run exits 0 (it is a listing, not an error)" "$rc" "0"
ck "all-skipped run shows skipped at step level"      "$(grep -c 'step 2 Build image => skipped' "$T/out")" "1"
ck "all-skipped output DIFFERS from all-success"      \
   "$(cmp -s "$T/out" "$T/out-success" && echo identical || echo different)" "different"

# ── 3) zero jobs is a failure, not an empty listing ─────────────────────────
run_jobs no-jobs.json 200; rc=$?
ck "zero jobs exits non-zero"                         "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
ck "zero jobs says so loudly"                         "$(grep -c 'ZERO jobs' "$T/out")" "1"

# ── 4) jobs present but zero steps (queued run) is also a failure ───────────
run_jobs no-steps.json 200; rc=$?
ck "zero steps exits non-zero"                        "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
ck "zero steps says so loudly"                        "$(grep -c 'ZERO steps' "$T/out")" "1"

# ── 5) HTTP errors are failures — a 404 used to exit 0 with a jq error ──────
run_jobs not-found.json 404; rc=$?
ck "HTTP 404 exits non-zero"                          "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
ck "HTTP 404 reports the status and the message"      \
   "$(grep -c 'HTTP 404 .* Not Found' "$T/out")" "1"
ck "HTTP 404 never prints a job listing"              "$(grep -c '^JOB ' "$T/out")" "0"

run_jobs bad-credentials.json 401; rc=$?
ck "HTTP 401 exits non-zero"                          "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
ck "HTTP 401 reports the credentials message"         "$(grep -c 'Bad credentials' "$T/out")" "1"

# ── 6) unauthenticated: refused BEFORE any request is made ─────────────────
: > "$GH_API_STUB_CALLS"
run_jobs all-success.json 200 ""; rc=$?
ck "empty GH_TOKEN exits non-zero"                    "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
ck "empty GH_TOKEN says it would be unauthenticated"  "$(grep -c 'unauthenticated' "$T/out")" "1"
ck "empty GH_TOKEN makes no request at all"           "$(wc -l < "$GH_API_STUB_CALLS" | tr -d ' ')" "0"

# ── 7) every failure path is non-silent: a non-zero exit always carries text ─
for _case in no-jobs.json no-steps.json not-found.json; do
    _code=200; [ "$_case" = "not-found.json" ] && _code=404
    run_jobs "$_case" "$_code"
    ck "$_case failure prints a message (silence is the defect)" \
       "$([ -s "$T/out" ] && echo yes || echo no)" "yes"
done

echo "── gh-api.sh jobs: $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
