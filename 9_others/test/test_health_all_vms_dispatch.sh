#!/bin/sh
# test_health_all_vms_dispatch.sh — the fleet health probe must not report green
# without checking anything.
#
# Debt #20/L5. cloud-health-all-vms.sh is registered as the
# `health_system-resources` probe (c3-morpheus probes.json, linux + android) and
# shipped as a Dagu DAG, and it was broken three ways at once, every one
# fail-green:
#   • dispatched health.yml / health-http-public.yml / health-http-private.yml,
#     none of which exist, each with `|| echo WARN` or `|| true`;
#   • called cloud-health-check-vm.sh with one argument when it requires two,
#     so every check died on the usage guard and `|| echo FAIL` ate it;
#   • hardcoded a VM list naming the retired gcp-t4.
#
# Runs against a stub cloud-health-check-vm.sh — no SSH, no VM, no gh.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/1_cicd/src/ops/cloud-health-all-vms.sh"
REGISTRY="$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
nope() { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (expected '$3', got '$2')"; fi; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

echo "== 1: dispatches no workflow that does not exist =="

# Comments are stripped throughout this section: the repaired script documents
# the defect by naming the three phantom workflows and gcp-t4 in its header,
# which is a record of the bug, not an instance of it. Only live code counts.
CODE=$(grep -vE '^[[:space:]]*#' "$SCRIPT")

# Every `gh workflow run <f>` must name a file that is really in
# .github/workflows/. The three this script used to dispatch never were.
missing=""
for wf in $(printf '%s\n' "$CODE" | grep -oE 'gh workflow run "[^"]+"' | sed 's/.*"\(.*\)"/\1/'); do
    [ -f "$ROOT/.github/workflows/$wf" ] || missing="$missing $wf"
done
check "every dispatched workflow exists" "$(echo "$missing" | tr -d ' ')" ""

# The specific three, pinned by name so a copy-paste revival is caught.
for wf in health.yml health-http-public.yml health-http-private.yml; do
    if [ -f "$ROOT/.github/workflows/$wf" ]; then
        ok "$wf exists (dispatching it would be legitimate)"
    elif printf '%s\n' "$CODE" | grep -q "$wf"; then
        nope "$wf does not exist but is still referenced in live code"
    else
        ok "$wf not dispatched (it does not exist)"
    fi
done

echo "== 2: the VM list is derived, not hardcoded =="

check "no hardcoded VMS= list" "$(printf '%s\n' "$CODE" | grep -cE '^VMS=')" "0"
check "retired gcp-t4 not named in live code" "$(printf '%s\n' "$CODE" | grep -c 'gcp-t4')" "0"

if [ -f "$REGISTRY" ]; then
    # Permanent mesh members carry a wg_ip; the on-demand GPU boxes do not and
    # must stay out, or a stopped rental turns the probe permanently red.
    derived=$(jq -r '.vms|to_entries[]|.value|select(.ssh_alias and .wg_ip)|.ssh_alias' "$REGISTRY" | sort | tr '\n' ' ')
    check "derives exactly the permanent mesh VMs" "$derived" "gcp-proxy oci-analytics oci-apps oci-mail "
    excluded=$(jq -r '.vms|to_entries[]|.value|select(.ssh_alias and (.wg_ip|not))|.ssh_alias' "$REGISTRY" | sort | tr '\n' ' ')
    check "on-demand GPU boxes excluded" "$excluded" "gcp-gpu-embed vast-ollama "
else
    echo "  SKIP: registry not built"
fi

echo "== 3: a failing VM makes the probe fail =="

if [ ! -f "$REGISTRY" ]; then
    echo "  SKIP: registry not built"
else
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    cp "$SCRIPT" "$WORK/"

    # Stub stands in for the real per-VM check; it also records the argv it was
    # given, which is how we prove the missing-ports bug is gone.
    cat > "$WORK/cloud-health-check-vm.sh" <<'STUB'
#!/bin/sh
echo "$#" >> "$ARGV_LOG"
[ "$1" = "$FAIL_ALIAS" ] && exit 1
exit 0
STUB
    chmod +x "$WORK/cloud-health-check-vm.sh"

    ARGV_LOG="$WORK/argv"; export ARGV_LOG
    : > "$ARGV_LOG"
    FAIL_ALIAS=oci-mail; export FAIL_ALIAS
    CLOUD_DATA_JSON="$REGISTRY" bash "$WORK/cloud-health-all-vms.sh" >/dev/null 2>&1
    check "one unhealthy VM exits non-zero" "$?" "1"
    # The pre-fix bug in one assertion: it passed ONE arg, so the real script
    # died on `${2:?}` before doing any work.
    check "always passes alias AND ports" "$(sort -u "$ARGV_LOG" | tr -d '\n')" "2"
    check "checks every VM, not just up to the first failure" "$(grep -c . "$ARGV_LOG")" "4"

    : > "$ARGV_LOG"
    FAIL_ALIAS=__none__; export FAIL_ALIAS
    CLOUD_DATA_JSON="$REGISTRY" bash "$WORK/cloud-health-all-vms.sh" >/dev/null 2>&1
    check "all healthy exits zero" "$?" "0"

    # An empty//absent registry must fail, never report a healthy empty fleet.
    echo '{"vms":{}}' > "$WORK/empty.json"
    CLOUD_DATA_JSON="$WORK/empty.json" bash "$WORK/cloud-health-all-vms.sh" >/dev/null 2>&1
    check "empty registry refuses to report healthy" "$?" "1"
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass assertions)"; exit 0; fi
echo "FAIL ($fail of $((pass+fail)))"
exit 1
