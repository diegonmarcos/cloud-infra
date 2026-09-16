#!/usr/bin/env bash
# Guard for the failure parser of 1_cicd/src/ops/cloud-health-mail-full.sh (#398).
#
# The defect: every layer of that reporter, on every non-zero outcome, appended
# one hardcoded string — "SSH/docker error". It was chosen without reading the
# command's output, and on the liveness layer the output was not even captured,
# because the remote stderr went to the job log and only the exit status came
# back. So maddy refusing a login, an image that would not pull, a crashed probe
# script and a dropped WireGuard session all reached the report and the ntfy
# alert as the same sentence. Two of those four are not mail faults at all, and
# nothing in the output told the reader which one had happened.
#
# This tester therefore asserts three things, and a grep for the old string
# would only have caught the first:
#
#   1. The parser names the REAL cause, from fixtures of six distinct failures.
#   2. A transport fault is routed to its own bucket and its own exit status —
#      exit 2 INCONCLUSIVE, not exit 1 FAILED — because "I could not look" and
#      "mail is broken" are different pages for different people.
#   3. The hardening that keeps the transport up in the first place (BatchMode,
#      the ServerAlive keepalive pair) is still declared.
#
# Cases 7-9 run the REAL reporter end to end with ssh stubbed, so a future
# rewrite that reintroduces a fixed label some other way still fails here.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/1_cicd/src/ops/cloud-health-mail-failure-classifier.sh"
REPORTER="$ROOT/1_cicd/src/ops/cloud-health-mail-full.sh"
RULES="$ROOT/9_others/mail-health-diagnosis.json"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

for f in "$LIB" "$REPORTER" "$RULES"; do
    [ -f "$f" ] || { echo "  FAIL missing $f"; exit 1; }
done
. "$LIB"

# ── 1. Six fixtures, six distinct causes. Each is a real string one of these
#      commands prints; all six used to produce "SSH/docker error".
cause() { mail_health_classify "$1" "$2" | cut -f1,2 | tr '\t' '/'; }

ck "broken pipe mid-report        -> transport" \
   "$(cause 255 'client_loop: send disconnect: Broken pipe')" "transport/ssh-session-dropped"
ck "mesh down, no route           -> transport" \
   "$(cause 255 'ssh: connect to host 10.0.0.6 port 22: No route to host')" "transport/ssh-host-unreachable"
ck "ssh 255 with an empty message -> transport" \
   "$(cause 255 '')" "transport/ssh-failed-without-message"
ck "container gone on oci-apps    -> docker" \
   "$(cause 1 'Error response from daemon: No such container: cloud-mail-mcp')" "docker/docker-container-absent"
ck "maddy refuses the login       -> mail" \
   "$(cause 1 'A1 NO [AUTHENTICATIONFAILED] Invalid credentials')" "mail/mail-store-auth-rejected"
ck "probe script crashed          -> remote-script" \
   "$(cause 1 'ModuleNotFoundError: No module named googleapiclient')" "remote-script/remote-script-crashed"

# An unrecognised failure must say it is unrecognised and carry the evidence
# onward. Guessing "transport" or "mail" here would be the original defect with
# better wording.
ck "unrecognised failure          -> unknown" \
   "$(cause 1 'the frobnicator disengaged')" "unknown/unclassified"

# ── 2. The rule set's own invariants. Both of these fail silently in
#      production: a misplaced fallback swallows every later rule, and a
#      backslash survives jq's @tsv doubled and stops matching.
ck "terminal fallback is declared exactly once" \
   "$(jq '[.failure_causes[] | select(has("pattern") | not) | select(has("exit_status") | not)] | length' "$RULES")" "1"
ck "terminal fallback is the LAST rule" \
   "$(jq -r '.failure_causes[-1] | if (has("pattern") | not) and (has("exit_status") | not) then "yes" else "no" end' "$RULES")" "yes"
ck "no pattern contains a backslash (jq @tsv doubles it)" \
   "$(jq -r '[.failure_causes[] | select(.pattern // "" | test("\\\\"))] | length' "$RULES")" "0"

# ── 3. Routing: which bucket, which verdict.
route() { # $1=exit status $2=evidence -> "transport-count:mail-count"
    ( FAIL_REASONS=(); TRANSPORT_FAILURES=()
      mail_health_record_failure "layer" "$1" "$2" >/dev/null
      echo "${#TRANSPORT_FAILURES[@]}:${#FAIL_REASONS[@]}" )
}
ck "broken pipe routes to the transport bucket" "$(route 255 'Broken pipe')" "1:0"
ck "docker fault routes to the mail bucket"     "$(route 1 'No such container: x')" "0:1"
ck "unclassified routes to the mail bucket"     "$(route 1 'mystery')" "0:1"

# ── 4. The hardened SSH invocation is still declared. Deleting the keepalive
#      pair is what turned a 30-second mesh blip into a dead liveness session.
opts="$(mail_health_ssh_options | tr '\n' ' ')"
for want in BatchMode=yes ServerAliveInterval ServerAliveCountMax TCPKeepAlive ConnectTimeout; do
    case "$opts" in *"$want"*) r=yes ;; *) r=no ;; esac
    ck "ssh_options declare $want" "$r" "yes"
done
ck "ServerAliveCountMax is above the 3 that killed runs 34995321325/35022772131" \
   "$(jq -r '[.ssh_options[] | capture("ServerAliveCountMax=(?<n>[0-9]+)").n] | first | tonumber > 3' "$RULES")" "true"

# ── 5. End to end against the real reporter, with ssh stubbed. REPO_ROOT points
#      at an empty tree so layers 2 and 3 take their "script not in the
#      checkout" branches and never ssh; only layer 1 does, and its stub decides
#      what kind of failure the run sees.
mkdir -p "$T/bin" "$T/emptyrepo"
cat > "$T/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$MAIL_HEALTH_TEST_SSH_STDERR" >&2
printf '%s\n' "$MAIL_HEALTH_TEST_SSH_STDOUT"
# Deliberately does NOT drain stdin. Real ssh with -n does not either, and a
# stub that did blocked the ntfy call on the harness's own stdin for the whole
# `timeout 60` of every case. Nothing here feeds ssh through a pipe, so no
# writer gets SIGPIPE from the stub exiting early.
exit "$MAIL_HEALTH_TEST_SSH_RC"
STUB
chmod +x "$T/bin/ssh"

run_reporter() { # $1=stderr $2=stdout $3=rc -> "exit=<n> verdict=<first result line>"
    local out rc
    out=$(PATH="$T/bin:$PATH" \
          GITHUB_WORKSPACE="$T/emptyrepo" \
          MAIL_HEALTH_TEST_SSH_STDERR="$1" \
          MAIL_HEALTH_TEST_SSH_STDOUT="$2" \
          MAIL_HEALTH_TEST_SSH_RC="$3" \
          bash "$REPORTER" </dev/null 2>&1); rc=$?
    echo "exit=$rc verdict=$(printf '%s\n' "$out" | grep -m1 -o 'Mail Health [A-Z]*')"
}

ck "transport fault  -> exit 2, INCONCLUSIVE" \
   "$(run_reporter 'client_loop: send disconnect: Broken pipe' '' 255)" \
   "exit=2 verdict=Mail Health INCONCLUSIVE"
ck "docker fault     -> exit 1, FAILED (a mail verdict, not a transport one)" \
   "$(run_reporter 'Error response from daemon: No such container: cloud-mail-mcp' '' 1)" \
   "exit=1 verdict=Mail Health FAILED"
ck "unparseable report -> exit 1, FAILED" \
   "$(run_reporter '' 'not json' 0)" \
   "exit=1 verdict=Mail Health FAILED"

# The named cause must reach the report text, not just the exit code.
ck "the report names the broken pipe by cause" \
   "$(PATH="$T/bin:$PATH" GITHUB_WORKSPACE="$T/emptyrepo" \
      MAIL_HEALTH_TEST_SSH_STDERR='client_loop: send disconnect: Broken pipe' \
      MAIL_HEALTH_TEST_SSH_STDOUT='' MAIL_HEALTH_TEST_SSH_RC=255 \
      bash "$REPORTER" </dev/null 2>&1 | grep -c 'ssh-session-dropped')" "2"

# ── 6. The reporter must classify on every failure path rather than pin a
#      label. Three layers, three call sites, and no fixed cause string left.
ck "reporter sources the classifier" \
   "$(grep -c '^\. .*cloud-health-mail-failure-classifier\.sh' "$REPORTER")" "1"
ck "reporter classifies on all three layers" \
   "$(grep -c '^\s*mail_health_record_failure ' "$REPORTER")" "3"
ck "no runtime failure string says SSH/docker error" \
   "$(grep -n 'SSH/docker error' "$REPORTER" | grep -vc '^[0-9]*:#')" "0"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
