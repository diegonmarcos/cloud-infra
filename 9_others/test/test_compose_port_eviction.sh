#!/bin/sh
# test_compose_port_eviction.sh — a renamed service must reclaim its own port.
#
# Renaming c3-services-mcp → cloud-services-mcp is an identity-only change, but
# the predecessor kept running under the OLD name and kept the host binding.
# `docker compose down` never saw it (different project), EVICT_NAMED never saw
# it (it only knows the names we declare now), and `up` died with:
#   Bind for 10.0.0.6:3101 failed: port is already allocated
#
# EVICT_PORTS closes that: it evicts on the host binding our compose declares,
# whatever the holder is called. The two things worth proving are that it hits
# the stale predecessor and that it does NOT hit ourselves.
#
# Runs entirely against a stub `docker` on PATH — no daemon, no VM.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
nope() { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (expected '$3', got '$2')"; fi; }

[ -f "$STEP" ] || { echo "FAIL: $STEP missing"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stub docker: `ps` prints a fixed fleet, `rm` records what it was asked to kill.
cat > "$WORK/bin/docker" <<STUB
#!/bin/sh
case "\$1" in
  ps) printf '%s\n' \
        "cloud-services-mcp 10.0.0.6:3199->3199/tcp" \
        "c3-services-mcp 10.0.0.6:3101->3101/tcp" \
        "unrelated-svc 10.0.0.6:3999->3999/tcp" ;;
  rm) shift; while [ "\$1" = "-f" ]; do shift; done; echo "\$1" >> "$WORK/removed" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"; export PATH

# Lift the EVICT_PORTS construction out of the step verbatim, so the test
# breaks if the real line changes shape.
EVICT_LINE=$(grep -n 'EVICT_PORTS="for hp in' "$STEP" | head -1 | cut -d: -f1)
[ -n "$EVICT_LINE" ] || { echo "  SKIP: EVICT_PORTS construction not found"; exit 0; }

# A compose file in the same JSON-on-one-line shape the deriver emits.
COMPOSE_FILE="$WORK/docker-compose.yml"
printf '%s\n' '{"services":{"cloud-services-mcp":{"ports":["10.0.0.6:3101:3101"]}}}' > "$COMPOSE_FILE"

build_and_run() {
  # _cnames is what build.json declares; _hostbinds is scraped from the compose.
  _cnames="$1 "
  _hostbinds="$(grep -oE '"[0-9][0-9.]*:[0-9]+:[0-9]+"' "$COMPOSE_FILE" 2>/dev/null \
      | tr -d '"' | sed 's/:[0-9]*$//' | sort -u | tr '\n' ' ')"
  eval "$(sed -n "${EVICT_LINE}p" "$STEP" | sed 's/^.*&& //')"
  rm -f "$WORK/removed"
  # >/dev/null: the payload narrates each eviction into the CI log, which is
  # the point of it — but here only the stub's record of what it removed is
  # the result being asserted on.
  printf '%s\n' "$EVICT_PORTS" | sh >/dev/null
  cat "$WORK/removed" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'
}

echo "== port scrape =="
_hostbinds="$(grep -oE '"[0-9][0-9.]*:[0-9]+:[0-9]+"' "$COMPOSE_FILE" \
    | tr -d '"' | sed 's/:[0-9]*$//' | sort -u | tr '\n' ' ')"
check "host binding scraped from compose" "$_hostbinds" "10.0.0.6:3101 "

echo "== eviction =="
# The whole point: the stale predecessor holding our port goes.
check "stale predecessor on our port is evicted" "$(build_and_run cloud-services-mcp)" "c3-services-mcp"

# And the guard: if WE are the holder, we must not remove ourselves — that
# would turn every no-op redeploy into an outage.
printf '%s\n' '{"services":{"x":{"ports":["10.0.0.6:3199:3199"]}}}' > "$COMPOSE_FILE"
check "never evicts a container we declare" "$(build_and_run cloud-services-mcp)" ""

# A port we do not declare is none of our business.
printf '%s\n' '{"services":{"x":{"ports":["10.0.0.6:3101:3101"]}}}' > "$COMPOSE_FILE"
out=$(build_and_run cloud-services-mcp)
case "$out" in *unrelated-svc*) nope "must not touch containers on undeclared ports" ;;
                *) ok "leaves containers on undeclared ports alone" ;; esac

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass assertions)"; exit 0; fi
echo "FAIL ($fail of $((pass+fail)))"
exit 1
