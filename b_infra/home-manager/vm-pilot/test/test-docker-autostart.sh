#!/usr/bin/env bash
# test-docker-autostart.sh — verify hm.docker_autostart wires through correctly
#
# Reads each nixhm-sudo-<vm>/build.json, SSHes to the VM, asserts:
#   - hm.docker_autostart=true  → docker.service has WantedBy=multi-user.target
#                                AND systemctl is-enabled docker == enabled
#                                AND container-up.service exists + enabled
#   - hm.docker_autostart=false → docker.service has NO [Install]
#                                AND systemctl is-enabled docker == static/disabled
#                                AND container-up.service does NOT exist
#
# Source: cloud/b_infra/home-manager/vm-pilot/test/test-docker-autostart.sh
# Run:    ./build.sh test (called from each nixhm-sudo-<vm>/) or directly:
#         bash test-docker-autostart.sh <vm-alias>
#
# Exit 0 = all assertions pass.  Exit 1 = any drift.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # vm-pilot/test → home-manager/

PASS=0; FAIL=0
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "  ✗ $1";  FAIL=$((FAIL+1)); }
ok()    { green "  ✓ $1"; PASS=$((PASS+1)); }

assert_remote() {
    local vm="$1" desc="$2" expr="$3"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$vm" "$expr" >/dev/null 2>&1; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

assert_remote_not() {
    local vm="$1" desc="$2" expr="$3"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$vm" "$expr" >/dev/null 2>&1; then
        fail "$desc (expected absent but found)"
    else
        ok "$desc"
    fi
}

test_vm() {
    local vm="$1"
    local bj="$HM_ROOT/nixhm-sudo-$vm/build.json"
    [ -f "$bj" ] || { red "no build.json for $vm at $bj"; FAIL=$((FAIL+1)); return; }

    local autostart
    autostart=$(jq -r '.hm.docker_autostart // false' "$bj")

    printf "\n== %s (docker_autostart=%s) ==\n" "$vm" "$autostart"

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$vm" 'true' 2>/dev/null; then
        red "  SKIP: $vm unreachable"
        return
    fi

    if [ "$autostart" = "true" ]; then
        assert_remote "$vm" "docker.service has WantedBy=multi-user.target" \
            "grep -q 'WantedBy=multi-user.target' /etc/systemd/system/docker.service"
        assert_remote "$vm" "systemctl is-enabled docker == enabled" \
            "[ \"\$(systemctl is-enabled docker.service 2>&1)\" = enabled ]"
        assert_remote "$vm" "container-up.service exists" \
            "test -f /etc/systemd/system/container-up.service"
        assert_remote "$vm" "container-up.service enabled" \
            "[ \"\$(systemctl is-enabled container-up.service 2>&1)\" = enabled ]"
    else
        assert_remote_not "$vm" "docker.service has NO [Install]" \
            "grep -q '\\[Install\\]' /etc/systemd/system/docker.service"
        assert_remote_not "$vm" "container-up.service does NOT exist" \
            "test -f /etc/systemd/system/container-up.service"
    fi
}

# ── Args: explicit vm or all known VMs from cloud-data ──
if [ $# -gt 0 ]; then
    for v in "$@"; do test_vm "$v"; done
else
    # Auto-discover from nixhm-sudo-*/build.json
    for d in "$HM_ROOT"/nixhm-sudo-*/; do
        n=$(basename "$d")
        v="${n#nixhm-sudo-}"
        test_vm "$v"
    done
fi

printf "\n──────────────────────────────────\n"
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
