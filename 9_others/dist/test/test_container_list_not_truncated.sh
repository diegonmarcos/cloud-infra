#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_container_list_not_truncated.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_container_list_not_truncated.sh — the ship engine must never act on a
# PARTIAL list of a service's containers.
#
# Debt #20/L3. Both the status step and the compose deploy step read the
# declared container names with, verbatim:
#
#     _cnames="$(jq -r '.containers[]?.container_name // empty' build.json 2>/dev/null)"
#
# containers{} is a MAP and `.containers[]?` iterates its VALUES; the `?` only
# suppresses "cannot iterate", it does not make the body total. infra-db_postlite
# carried a "_doc_*" note STRING among those values, so `.container_name` aborted
# jq mid-stream: the names emitted before the bad entry stayed on stdout, the
# reason went to stderr where `2>/dev/null` deleted it, and exit 5 was discarded
# by `$(...)` on the right-hand side of an assignment — invisible even to set -e.
# Caller got 3 of postlite's 8 containers and a success status. STATUS reported
# green on containers it never looked at; DEPLOY never evicted the ones it
# missed. A silent wrong answer, which is why it is worth a test of its own.
#
# What is actually proven here: given a malformed containers{}, the engine
# REFUSES (non-zero, nothing usable on stdout). "Prints a short list and exits
# 0" must be unreachable. Part 2 additionally pins the real fleet data.
#
# Runs against the engine's own declared_container_names() — no VM, no docker,
# no daemon. jq is the only dependency.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ENGINE="$ROOT/1_cicd/src/scripts/cloud-ship-container-engine.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
nope() { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (expected '$3', got '$2')"; fi; }

[ -f "$ENGINE" ] || { echo "FAIL: $ENGINE missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Lift declared_container_names() out of the engine verbatim, so this test
# breaks if the real function changes shape. Sourcing the engine itself is not
# an option: it runs a full argument parse and step-sourcing pass at load.
sed -n '/^declared_container_names() {/,/^}/p' "$ENGINE" > "$WORK/fn.sh"
[ -s "$WORK/fn.sh" ] || { echo "FAIL: declared_container_names() not found in engine"; exit 1; }

# The engine defines these; the function reports through them.
log_error() { echo "LOG_ERROR: $1" >&2; }
# shellcheck disable=SC1090
. "$WORK/fn.sh"

echo "== 1: a malformed containers{} must fail loudly, not truncate =="

# The exact shape postlite had: three good entries, a note string, four more
# good entries. The entries AFTER the bad one are the ones silently lost.
cat > "$WORK/malformed.json" <<'JSON'
{
  "name": "fixture",
  "containers": {
    "a": { "container_name": "ctr-a" },
    "b": { "container_name": "ctr-b" },
    "c": { "container_name": "ctr-c" },
    "_doc_d": "a note that has no business being an entry in this map",
    "e": { "container_name": "ctr-e" },
    "f": { "container_name": "ctr-f" }
  }
}
JSON

out=$(declared_container_names "$WORK/malformed.json" 2>/dev/null); rc=$?
check "malformed containers{} exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
# The regression in one assertion: the old expression returned "ctr-a ctr-b
# ctr-c" here with rc=0. Any non-empty stdout is a partial list the caller
# would act on.
check "malformed containers{} yields no usable list" "$(printf '%s' "$out" | tr -d '[:space:]')" ""
# The operator has to be able to find the offending key from the log alone.
err=$(declared_container_names "$WORK/malformed.json" 2>&1 >/dev/null)
case "$err" in *_doc_d*) ok "error names the offending key" ;;
               *)        nope "error must name the offending key (got: $err)" ;; esac

echo "== 2: a well-formed containers{} returns EVERY entry =="

cat > "$WORK/wellformed.json" <<'JSON'
{
  "name": "fixture",
  "_doc_containers": "a note in its correct place: BESIDE containers{}, not inside it",
  "containers": {
    "a": { "container_name": "ctr-a" },
    "b": { "container_name": "ctr-b" },
    "c": { "container_name": "ctr-c" },
    "e": { "container_name": "ctr-e" },
    "f": { "container_name": "ctr-f" }
  }
}
JSON

out=$(declared_container_names "$WORK/wellformed.json" 2>/dev/null); rc=$?
check "well-formed containers{} exits zero" "$rc" "0"
check "returns all 5, in declaration order" "$(printf '%s' "$out" | tr '\n' ' ')" "ctr-a ctr-b ctr-c ctr-e ctr-f"
check "a sibling _doc_containers key is not mistaken for a container" \
      "$(printf '%s' "$out" | grep -c 'note in its correct place')" "0"

echo "== 3: the empty and missing cases stay distinguishable =="

# No containers{} at all is legitimate (proxy-only services) — empty list, rc 0,
# so callers keep their existing "nothing to do" arm.
printf '%s\n' '{"name":"fixture"}' > "$WORK/nocontainers.json"
out=$(declared_container_names "$WORK/nocontainers.json" 2>/dev/null); rc=$?
check "absent containers{} exits zero" "$rc" "0"
check "absent containers{} returns empty" "$(printf '%s' "$out" | tr -d '[:space:]')" ""

# Unparseable JSON is a hard error, never an empty list — an empty list reads as
# "this service has no containers" and would skip eviction entirely.
printf '%s\n' '{"name": broken' > "$WORK/broken.json"
out=$(declared_container_names "$WORK/broken.json" 2>/dev/null); rc=$?
check "unparseable build.json exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

declared_container_names "$WORK/does-not-exist.json" >/dev/null 2>&1; rc=$?
check "missing build.json exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

echo "== 4: every build.json in the fleet has an iterable containers{} =="

# a_solutions/ is a CI-time checkout of cloud-u-containers, gitignored here and
# absent on a bare clone (see .gitmodules note, 2026-09-06). Skip rather than
# fail when it is not present — part 1 is the portable proof.
if [ -d "$ROOT/a_solutions" ]; then
    bad=""
    for bj in "$ROOT"/a_solutions/*/build.json; do
        [ -f "$bj" ] || continue
        if ! declared_container_names "$bj" >/dev/null 2>&1; then
            bad="$bad $(basename "$(dirname "$bj")")"
        fi
    done
    check "no build.json carries a non-object in containers{}" "$(echo "$bad" | tr -d ' ')" ""

    # The regression itself, pinned by name. postlite's compose runs 8
    # containers; it DECLARES the 7 it owns, and postlite-authelia is declared
    # by its owner infra-sec_authelia ("the owner declares, the catalogue only
    # points"). Before the fix the engine saw 3.
    POSTLITE="$ROOT/a_solutions/infra-db_postlite/build.json"
    if [ -f "$POSTLITE" ]; then
        n=$(declared_container_names "$POSTLITE" 2>/dev/null | grep -c .)
        check "postlite resolves every container it declares" "$n" "7"
        check "postlite-authelia is declared by its owner" \
          "$(declared_container_names "$ROOT/a_solutions/infra-sec_authelia/build.json" 2>/dev/null \
             | grep -c '^postlite-authelia$')" "1"
    else
        echo "  SKIP: infra-db_postlite not in the a_solutions checkout"
    fi
else
    echo "  SKIP: a_solutions/ not checked out (runs in CI)"
fi

echo "== 5: no consumer may re-derive the list with its own jq =="

# The bug was one expression copy-pasted into two steps. A third copy would
# reintroduce it silently, so the shape itself is banned as live code.
# Comment lines are excluded on purpose: the engine quotes the old expression
# verbatim in declared_container_names()'s header, which is documentation of
# the defect, not an instance of it.
copies=$(grep -rn 'containers\[\]?\.container_name' "$ROOT/1_cicd/src" 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*: *#' | grep -c .)
check "no step re-derives containers[].container_name inline" "$copies" "0"

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass assertions)"; exit 0; fi
echo "FAIL ($fail of $((pass+fail)))"
exit 1
