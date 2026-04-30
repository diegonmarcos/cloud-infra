#!/usr/bin/env bash
# test_etc_hosts_clean.sh — assert /etc/hosts contains NO *.diegonmarcos.com
# hijacks on any VM. Caddy is the sole route owner; loopback/internal hijacks
# bypass it and create silent inconsistencies (e.g. cypht trying to reach
# mail.diegonmarcos.com from oci-mail hits local Maddy, no JMAP listener).
#
# Build-time checks: module source exists + wired into vm-pilot/default.nix.
# Runtime checks: ssh each VM and grep /etc/hosts (skipped if unreachable).
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo "[PASS] $label"
    PASS=$(( PASS + 1 ))
  else
    echo "[FAIL] $label"
    FAIL=$(( FAIL + 1 ))
  fi
}

CLOUD_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MOD="$CLOUD_ROOT/b_infra/home-manager/vm-pilot/src/modules/network/etc-hosts-clean.nix"
DEFAULT="$CLOUD_ROOT/b_infra/home-manager/vm-pilot/src/modules/default.nix"

# ── Build-time: module source + wiring ──────────────────────────────────────
echo "==> 1. Build-time: module source + wiring"
check "etc-hosts-clean.nix module exists" \
    test -f "$MOD"
check "module declares home.activation hook" \
    grep -q 'home.activation.etcHostsCleanCaddySoT' "$MOD"
check "module strips *.diegonmarcos.com lines (regex present)" \
    grep -q 'diegonmarcos' "$MOD"
check "module imported by vm-pilot/default.nix" \
    grep -q 'etc-hosts-clean.nix' "$DEFAULT"
check "module ordered AFTER dns-hickory.nix in default.nix" \
    bash -c "grep -nE 'dns-hickory|etc-hosts-clean' '$DEFAULT' | head -2 | awk -F: '{print \$1}' | sort -nc"

# ── Runtime: assert no hijacks present on each VM (skip if unreachable) ─────
echo ""
echo "==> 2. Runtime: /etc/hosts on every VM has zero *.diegonmarcos.com hijacks"

VMS=(oci-mail oci-apps oci-analytics gcp-proxy gcp-t4)

for vm in "${VMS[@]}"; do
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$vm" true 2>/dev/null; then
        echo "[SKIP] $vm: unreachable"
        continue
    fi
    if ssh "$vm" "grep -E '\.diegonmarcos\.com' /etc/hosts 2>/dev/null" 2>/dev/null | grep -q .; then
        echo "[FAIL] $vm: /etc/hosts still has *.diegonmarcos.com hijack(s):"
        ssh "$vm" "grep -E '\.diegonmarcos\.com' /etc/hosts 2>&1" | sed 's/^/         /'
        FAIL=$(( FAIL + 1 ))
    else
        echo "[PASS] $vm: /etc/hosts is clean (no diegonmarcos.com hijacks)"
        PASS=$(( PASS + 1 ))
    fi
done

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
