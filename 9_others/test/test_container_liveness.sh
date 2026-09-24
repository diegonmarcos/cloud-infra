#!/usr/bin/env bash
# #560 — a container in `created` is DEAD, and a deploy must not end green with one.
#
# An evicted deploy left my-ai-api in state `created`: compose created it and
# never started it — no logs, ExitCode 0. `docker ps -a` listed it, its digest
# matched the registry, and both telegram bots were down behind a deploy and a
# reconcile that each read healthy. step_compose ended with a `docker ps` that
# it logged and ignored; step_health only walked what `docker compose ps` lists,
# which omits a created container.
#
# This drives the REAL code: it sources the shipped step file and lifts
# declared_container_names out of the real engine, stubbing only the ssh
# transport. Verdicts are read from what the code prints and returns.
set -u
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPTS="$REPO_ROOT/1_cicd/src/scripts"
HEALTH="$SCRIPTS/cloud-ship-container-step-deploy-health.sh"
COMPOSE="$SCRIPTS/cloud-ship-container-step-deploy-compose.sh"
ENGINE="$SCRIPTS/cloud-ship-container-engine.sh"

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

log()       { printf '%s\n' "$*"; }
log_error() { printf 'ERROR %s\n' "$*"; }
log_warn()  { printf 'WARN %s\n' "$*"; }
# shellcheck disable=SC1090
. "$HEALTH"
eval "$(sed -n '/^declared_container_names() {/,/^}/p' "$ENGINE")"
ck "engine still defines declared_container_names" "$(type -t declared_container_names)" "function"

# ── The pure classifier ──
live() { printf '%s\n' "$3" | _container_liveness "$1" "$2" >"$WORK/v"; echo $?; }

ck "running is live" \
   "$(live "app" "" "/app|running|0")" "0"
ck "#560: created is DEAD" \
   "$(live "app db" "" "/app|created|0
/db|running|0")" "1"
ck "#560: the created container is named" \
   "$(grep -c '^DEAD app created' "$WORK/v")" "1"
ck "exited long-runner is DEAD" \
   "$(live "app" "" "/app|exited|137")" "1"
ck "exited one-shot with code 0 is live" \
   "$(live "app setup" "setup" "/app|running|0
/setup|exited|0")" "0"
ck "exited one-shot with a failing code is DEAD" \
   "$(live "setup" "setup" "/setup|exited|1")" "1"
ck "dead/paused/removing are DEAD" \
   "$(live "a b c" "" "/a|dead|0
/b|paused|0
/c|removing|0")" "1"
ck "  ...each named" "$(grep -c '^DEAD' "$WORK/v")" "3"
ck "missing is reported, not fatal" \
   "$(live "app gone" "" "/app|running|0")" "0"
ck "  ...and named MISSING" "$(grep -c '^MISSING gone' "$WORK/v")" "1"
# A name that is a prefix of another must not borrow its state.
ck "exact-name match, not prefix" \
   "$(live "app" "" "/app-db|running|0
/app|created|0")" "1"

# ── The VM-facing assertion, over a real build.json shape ──
SERVICE_DIR="$WORK/svc"; mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_DIR/build.json" <<'JSON'
{ "containers": {
    "app":   { "container_name": "my-ai-api" },
    "setup": { "container_name": "my-ai-setup", "one_shot": true } } }
JSON
DEPLOY_HOST=testvm
ssh_with_retry() { printf '%s' "$SSH_REPLY"; [ -n "$SSH_REPLY" ]; }
assert_rc() { SSH_REPLY="$1" assert_declared_containers_live >"$WORK/a" 2>&1; echo $?; }

ck "live fleet passes" \
   "$(assert_rc "/my-ai-api|running|0
/my-ai-setup|exited|0
__liveness_probed__")" "0"
ck "#560 incident shape (created, digest irrelevant) FAILS" \
   "$(assert_rc "/my-ai-api|created|0
/my-ai-setup|exited|0
__liveness_probed__")" "1"
ck "  ...naming my-ai-api" "$(grep -c 'DEAD my-ai-api created' "$WORK/a")" "1"
ck "one_shot is read from build.json (exited setup accepted above, rejected here)" \
   "$(SERVICE_DIR="$WORK/svc2"; mkdir -p "$SERVICE_DIR"; \
      jq '.containers.setup.one_shot = false' "$WORK/svc/build.json" > "$SERVICE_DIR/build.json"; \
      assert_rc "/my-ai-api|running|0
/my-ai-setup|exited|0
__liveness_probed__")" "1"
ck "an unanswered probe FAILS (never all-MISSING-and-green)" \
   "$(assert_rc "")" "1"
ck "  ...and says the host did not answer" "$(grep -c 'did not answer' "$WORK/a")" "1"

# ── Wiring: both deploy exits consult the assertion and honour its verdict ──
# Read from the shipped function bodies, so a call left in a comment or moved
# out of the function does not count.
body() { sed -n "/^$2() {/,/^}/p" "$1"; }
ck "step_compose ends on the liveness gate (deploy cannot END in created)" \
   "$(body "$COMPOSE" step_compose | grep -c '^[[:space:]]*assert_declared_containers_live || return 1$')" "1"
ck "step_compose no longer ends on a logged-and-ignored docker ps" \
   "$(body "$COMPOSE" step_compose | grep -c "docker ps --filter 'name=")" "0"
ck "step_health gates its success path on liveness" \
   "$(body "$HEALTH" step_health | grep -c '^[[:space:]]*assert_declared_containers_live || return 1$')" "1"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
