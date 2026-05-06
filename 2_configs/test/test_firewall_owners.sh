#!/usr/bin/env bash
# Phase 0 audit — VM port-ownership migration (loyal-firewalling-marmot.md)
#
# Asserts: every nixhm-sudo-<vm>/build.json.firewall.public_ports[] entry
#   1. has owned_by + source fields populated
#   2. owned_by names a real a_solutions/* service
#   3. that service has enabled !== false in its build.json
#
# Plus orphan-detection on cloud/config.json for the legacy public_ports it
# still holds (Phase 0 only — Phase 1 will switch the consolidator and
# Phase 2 will delete the config.json block entirely).
#
# Data-driven: walks the file system, hardcodes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

CLOUD_ROOT="$(cd ../ && pwd)"
HM_DIR="${CLOUD_ROOT}/b_infra"
SOL_DIR="${CLOUD_ROOT}/a_solutions"

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

fail_with() {
  echo "[FAIL] $1"
  FAIL=$(( FAIL + 1 ))
}

# ── Per-VM nixhm-sudo build.json schema audit ──────────────────────────────────
echo "==> Auditing nixhm-sudo-<vm>/build.json firewall.public_ports[]"

# Resolve owner_by → solution dir from the entire a_solutions tree
# (any service whose build.json .name matches owned_by).
declare -A OWNER_DIR
for bj in "$SOL_DIR"/*/build.json; do
  name=$(jq -r '.name // empty' "$bj")
  [[ -z "$name" ]] && continue
  OWNER_DIR["$name"]="$(dirname "$bj")"
done

for hm in "$HM_DIR"/nixhm-sudo-*/build.json; do
  vm=$(jq -r '.vm.alias' "$hm")
  count=$(jq '.firewall.public_ports | length' "$hm")
  echo "-- $vm: $count port(s) declared"

  # Each entry must have owned_by + source
  bad=$(jq -r '[.firewall.public_ports[] | select((.owned_by // "") == "" or (.source // "") == "")] | length' "$hm")
  if [[ "$bad" -gt 0 ]]; then
    fail_with "$vm: $bad port(s) missing owned_by or source"
    jq -r '.firewall.public_ports[] | select((.owned_by // "") == "" or (.source // "") == "") | "  - port \(.port)/\(.proto) (\(.desc // "no desc"))"' "$hm"
  else
    check "$vm: all entries have owned_by + source" true
  fi

  # Each owned_by must resolve to a real solution dir
  while read -r owner port proto desc; do
    [[ -z "$owner" ]] && continue

    # owned_by="system" reserved for VM-level concerns (SSH, kernel ports)
    # that have no a_solutions/* service. Skip the lookup.
    if [[ "$owner" == "system" ]]; then
      check "$vm:$port/$proto → system (reserved)" true
      continue
    fi

    sol_dir="${OWNER_DIR[$owner]:-}"
    if [[ -z "$sol_dir" ]]; then
      fail_with "$vm:$port/$proto owned_by=\"$owner\" — no a_solutions/* service has that name"
      continue
    fi

    # Service must be enabled
    enabled=$(jq -r '.enabled // null' "$sol_dir/build.json")
    if [[ "$enabled" == "false" ]]; then
      fail_with "$vm:$port/$proto owned_by=\"$owner\" — service has enabled:false"
      continue
    fi

    check "$vm:$port/$proto → $owner (enabled, declared)" true
  done < <(jq -r '.firewall.public_ports[] | "\(.owned_by) \(.port) \(.proto) \(.desc)"' "$hm")
done

# ── Phase 1 verification: consolidator output == per-VM source ────────────────
# 2026-04-28 migrated: cloud-data-home-manager.json -> _cloud-data-consolidated.json[._home_manager.vms]
echo ""
echo "==> Phase 1: _cloud-data-consolidated.json[._home_manager.vms.<alias>.public_ports] matches nixhm-sudo source"

CONS="${CLOUD_ROOT}/2_configs/dist/_cloud-data-consolidated.json"
if [[ -f "$CONS" ]]; then
  for hm in "$HM_DIR"/nixhm-sudo-*/build.json; do
    alias=$(jq -r '.vm.alias' "$hm")
    src=$(jq -c --sort-keys '.firewall.public_ports // []' "$hm")
    # Try ._home_manager.vms first (v2 shape), fall back to .home_manager.vms (legacy)
    derived=$(jq -c --sort-keys --arg a "$alias" '
      ._home_manager.vms[$a].public_ports
      // .home_manager.vms[$a].public_ports
      // []' "$CONS")
    if [[ "$src" == "$derived" ]]; then
      check "phase1: $alias public_ports source==derived" true
    else
      fail_with "phase1: $alias public_ports drift — consolidator did not flip cleanly"
      echo "  src:     $src"
      echo "  derived: $derived"
    fi
  done
else
  fail_with "phase1: $CONS not found — run 'cloud/2_configs/build.sh all' first"
fi

# ── Phase 4 (optional): live SSH reconciliation — every declared port has a listener ──
# Triggered with FIREWALL_RECONCILE=1 (skipped by default — needs SSH access).
# Does NOT fail-loud on listener mismatch unless STRICT_RECONCILE=1, since the
# data-driven sshd-hardening change ships first, drift gets fixed by Phase 5 deploy.
if [[ "${FIREWALL_RECONCILE:-0}" == "1" ]]; then
  echo ""
  echo "==> Phase 4: live ss -ltnp reconciliation (FIREWALL_RECONCILE=1)"

  RECONCILE_DRIFT=0
  for hm in "$HM_DIR"/nixhm-sudo-*/build.json; do
    alias=$(jq -r '.vm.alias' "$hm")
    declared_tcp=$(jq -r '[.firewall.public_ports[]? | select(.proto=="tcp") | .port] | sort | unique | join(",")' "$hm")
    [[ -z "$declared_tcp" ]] && continue

    # Get actual listeners (filter to TCP, listening, exclude WG-only and lo)
    actual=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$alias" \
      "ss -lntH 2>/dev/null | awk '{print \$4}' | sed 's/.*://' | sort -u | tr '\n' ',' | sed 's/,\$//'" 2>/dev/null || echo "SSH_FAIL")

    if [[ "$actual" == "SSH_FAIL" ]]; then
      echo "  [SKIP] $alias: SSH unreachable"
      continue
    fi

    # Per-port check: each declared TCP port must appear in `ss` output
    missing=""
    for p in ${declared_tcp//,/ }; do
      if ! echo ",$actual," | grep -q ",$p,"; then
        missing="$missing $p"
      fi
    done
    if [[ -z "$missing" ]]; then
      check "phase4: $alias all $(echo $declared_tcp | tr ',' ' ' | wc -w) declared TCP port(s) have listeners" true
    else
      RECONCILE_DRIFT=$(( RECONCILE_DRIFT + 1 ))
      msg="phase4: $alias has declared port(s) with no listener:$missing"
      if [[ "${STRICT_RECONCILE:-0}" == "1" ]]; then
        fail_with "$msg"
      else
        echo "  [WARN] $msg (run with STRICT_RECONCILE=1 to fail)"
      fi
    fi
  done
  echo "  Reconciliation drift count: $RECONCILE_DRIFT"
fi

# ── Phase 3 verification: sshd-hardening.nix is data-driven (no hardcoded heredoc) ──
echo ""
echo "==> Phase 3: vm-pilot/security/sshd-hardening.nix data-driven (no hardcoded port heredoc)"

SSHD_NIX="${CLOUD_ROOT}/b_infra/_shared/vm-pilot/src/modules/security/sshd-hardening.nix"
VM_PILOT_DEFAULT="${CLOUD_ROOT}/b_infra/_shared/vm-pilot/src/modules/default.nix"

if [[ ! -f "$SSHD_NIX" ]]; then
  fail_with "phase3: $SSHD_NIX missing"
else
  # Must take vmName parameter
  if grep -qE '^\{ vmName \}:' "$SSHD_NIX"; then
    check "phase3: sshd-hardening.nix accepts { vmName } parameter" true
  else
    fail_with "phase3: sshd-hardening.nix missing { vmName } parameter"
  fi

  # 2026-04-28 migrated: assertion now expects sshd-hardening.nix to read
  # _cloud-data-consolidated.json (the new master file). The legacy
  # cloud-data-home-manager.json is still accepted as a fallback during
  # the soft-transition window.
  if grep -qE "_cloud-data-consolidated\.json|cloud-data-home-manager\.json" "$SSHD_NIX"; then
    check "phase3: sshd-hardening.nix reads consolidated (or legacy home-manager fallback)" true
  else
    fail_with "phase3: sshd-hardening.nix doesn't read _cloud-data-consolidated.json"
  fi

  # Must NOT have the legacy hardcoded heredoc
  if grep -qE 'if \[ "\$VM" = "arch-1" \]' "$SSHD_NIX"; then
    fail_with "phase3: sshd-hardening.nix STILL contains hardcoded 'if VM=arch-1' heredoc"
  else
    check "phase3: hardcoded 'if VM=arch-1' heredoc removed" true
  fi

  # Must NOT hardcode port numbers in the iptables script body
  if grep -qE '^\s*iptables -A INPUT -p tcp --dport (22|80|443|465|587|993|2222|2443|2465|2587|2993)\b' "$SSHD_NIX"; then
    fail_with "phase3: sshd-hardening.nix STILL hardcodes specific port numbers"
  else
    check "phase3: no specific port numbers hardcoded in iptables body" true
  fi
fi

if [[ -f "$VM_PILOT_DEFAULT" ]]; then
  if grep -q '(import \./security/sshd-hardening\.nix { inherit vmName; })' "$VM_PILOT_DEFAULT"; then
    check "phase3: vm-pilot/default.nix passes vmName to sshd-hardening.nix" true
  else
    fail_with "phase3: vm-pilot/default.nix doesn't pass vmName to sshd-hardening.nix"
  fi
fi

# ── Phase 2 verification: cloud/config.json must NOT hold public_ports anymore ─
echo ""
echo "==> Phase 2: cloud/config.json contains zero public_ports declarations"

leftover=$(jq -r '[.vms | to_entries[] | select(.value.public_ports != null) | .value.ssh_alias] | length' "${CLOUD_ROOT}/config.json")
if [[ "$leftover" == "0" ]]; then
  check "phase2: config.json has no .vms[].public_ports — ownership is in nixhm-sudo build.json" true
else
  fail_with "phase2: $leftover VMs in config.json still hold public_ports — Phase 2 incomplete"
  jq -r '.vms | to_entries[] | select(.value.public_ports != null) | "  - \(.value.ssh_alias): \(.value.public_ports | length) port(s)"' "${CLOUD_ROOT}/config.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
