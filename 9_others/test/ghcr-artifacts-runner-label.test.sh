#!/bin/sh
# Regression test for PLAN-ghcr-artifacts.md item 4: an optional
# vms.<host>.runner_label lets the split ship.yml `deploy` job run directly
# on a self-hosted runner living on that VM (docker socket local — no
# ssh/rsync/WG), while staying behaviour-neutral (ubuntu-latest + the mesh
# path, exactly as today) for every host that doesn't set one.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SHIP_YML="$ROOT/1_cicd/src/cicd/ship.yml"
DERIVE_TS="$ROOT/1_cloud-configs/src/derive/cloud-data-config-consolidated.ts"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── 1) derive: runner_label propagated from vm.runner_label, not vm.gha.* ──
ck "consolidator reads vm.runner_label (top-level, not under .gha)" \
   "$(grep -c 'vm.runner_label ? { runner_label: vm.runner_label }' "$DERIVE_TS")" "1"

# ── 2) detect: RUNNER_LABEL_MAP built from the SAME GHA_CONFIG this step
#      already loaded (no new file to fail-open on) ──
ck "detect builds a runner_label map from GHA_CONFIG" \
   "$(grep -c 'RUNNER_LABEL_MAP=\$(jq -c' "$SHIP_YML")" "1"
ck "matrix entries carry runner_label (default empty string)" \
   "$(grep -c 'runner_label: (\$runner_label_map\[.vm\] // "")' "$SHIP_YML")" "1"

# ── 3) deploy job: runs-on falls back to ubuntu-latest when label is empty ──
ck "deploy runs-on uses matrix.runner_label with ubuntu-latest fallback" \
   "$(grep -c "runs-on: \${{ matrix.runner_label || 'ubuntu-latest' }}" "$SHIP_YML")" "1"

# ── 4) deploy job: WG_PRIVATE_KEY empties out when a label is set ──
ck "WG_PRIVATE_KEY is gated on an empty runner_label" \
   "$(grep -c "WG_PRIVATE_KEY: \${{ matrix.runner_label == '' && secrets.WG_PRIVATE_KEY || '' }}" "$SHIP_YML")" "1"

# ── 5) build job is untouched by any of this — it never had a runner_label
#      concept and must not gain one (build never deploys). Stop the range at
#      deploy's own leading comment block (not the literal "  deploy:" line)
#      since that comment mentions runner_label in prose while explaining the
#      deferred digest-pinning work — semantically deploy's, not build's.
ck "build job section has no runner_label reference" \
   "$(awk '/^  build:/{f=1} /^  # ── Deploy:/{f=0} f' "$SHIP_YML" | grep -c runner_label)" "0"

# ── 6) EXECUTED: the exact jq expressions used for the label map + matrix
#      fallback behave correctly for absent / present / empty-string cases ──
run_label_map() { # $1 = GHA_CONFIG json -> prints RUNNER_LABEL_MAP
  echo "$1" | jq -c '.vms | with_entries(.value = (.value.runner_label // ""))'
}
ck "no runner_label key at all -> empty string" \
   "$(run_label_map '{"vms":{"oci-apps":{"user":"ubuntu"}}}')" '{"oci-apps":""}'
ck "runner_label present -> passed through" \
   "$(run_label_map '{"vms":{"oci-apps":{"runner_label":"oci-apps-arm64"}}}')" '{"oci-apps":"oci-apps-arm64"}'

run_matrix_runner_label() { # $1=label_map $2=vm -> prints the matrix field's value
  jq -rn --argjson runner_label_map "$1" --arg vm "$2" '($runner_label_map[$vm] // "")'
}
ck "matrix field resolves to empty for an unmapped vm" "$(run_matrix_runner_label '{}' 'oci-apps')" ""
ck "matrix field resolves to the mapped label" \
   "$(run_matrix_runner_label '{"oci-apps":"oci-apps-arm64"}' 'oci-apps')" "oci-apps-arm64"

# ── 7) EXECUTED against GitHub: every configured runner_label must be a LABEL an
#      online self-hosted runner carries. runs-on matches labels, never names —
#      on 2026-08-26 the runner NAME (oci-apps-arm64) was configured and every
#      Deploy → oci-apps job queued forever (runs 32901095005, 32923957432).
#      Skips (does not fail) when gh is unavailable/unauthenticated so the suite
#      stays runnable offline; CI has gh.
CONFIG="$ROOT/config.json"
LABELS_CONFIGURED=$(jq -r '.vms | to_entries[] | select(.value.runner_label != null and .value.runner_label != "") | "\(.key)=\(.value.runner_label)"' "$CONFIG" 2>/dev/null)
if [ -n "$LABELS_CONFIGURED" ]; then
  if RUNNERS=$(gh api repos/diegonmarcos/cloud-infra/actions/runners --jq '.runners[] | select(.status=="online") | .labels[].name' 2>/dev/null) && [ -n "$RUNNERS" ]; then
    for _kv in $LABELS_CONFIGURED; do
      _lbl=${_kv#*=}
      ck "runner_label '$_lbl' (${_kv%%=*}) is a label of an online runner" \
         "$(printf '%s\n' "$RUNNERS" | grep -qx "$_lbl" && echo yes || echo no)" "yes"
    done
  else
    echo "  skip runner_label existence check (gh unavailable or unauthenticated)"
  fi
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
