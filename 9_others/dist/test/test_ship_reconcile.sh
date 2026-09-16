#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_reconcile.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Phase 48 — the reconcile names a deployed-behind-HEAD service without being told
#
# THE DEFECT UNDER TEST (#354)
#
# A deploy evicted from the ship-wg-runner concurrency queue is marked
# `cancelled` and never re-queued. The image is in GHCR, the fleet runs the old
# one, and every run in the list is green. Before cloud-ship-reconcile.sh there
# was NOTHING in the engine that compared those two facts, so the before-state
# of this test is not "a weaker check" — it is no check at all, which is why
# the fix had to be a new engine surface rather than a patch to detect.
#
# The test drives the real script with both of its impure operations injected,
# so it needs neither the fleet nor the network and is deterministic. The case
# that matters is case 2: it is the live casualty (user-ai_cloud-cgc-pub-mcp on
# oci-apps, Ship run 35034275746) reduced to fixtures — registry holds
# cb9c1b81…, the VM runs 23dc4f39…, and the reconcile must say so.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILE="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-reconcile.sh"

[ -f "$RECONCILE" ] || { echo "FAIL: $RECONCILE missing"; exit 1; }

pass=0; fail=0
ck() {
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Fixtures: two services on one VM, one upstream container ──────────────
# Declarations only. Nothing here names a service the script knows about; the
# script must learn every service, VM and container name from these files, so a
# hardcoded list in the engine would fail this test by finding nothing.
cat > "$WORK/build-gha.json" <<'JSON'
{
  "vms": { "testvm": { "wg_ip": "10.0.0.99" } },
  "services": {
    "pubmcp":  { "dir": "user-ai_cloud-cgc-pub-mcp", "vm": "testvm", "has_docker": true },
    "storage": { "dir": "infra-dat_storage",         "vm": "testvm", "has_docker": true }
  }
}
JSON

mkdir -p "$WORK/sol/user-ai_cloud-cgc-pub-mcp" "$WORK/sol/infra-dat_storage"
cat > "$WORK/sol/user-ai_cloud-cgc-pub-mcp/build.json" <<'JSON'
{ "containers": [ { "container_name": "cloud-cgc-pub-mcp" },
                  { "container_name": "cloud-cgc-pvt-mcp" } ] }
JSON
cat > "$WORK/sol/infra-dat_storage/build.json" <<'JSON'
{ "containers": [ { "container_name": "postgres" } ] }
JSON

REG_CURRENT="sha256:cb9c1b815a48e833703b2a51e321f71a78c1cbb46546136303dcb97fe7b11002"
VM_STALE="sha256:23dc4f39dca0448da1b6885035f16a19c0292344d5cff9f86ee84d4171df1001"
OURS="ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries:latest"

# Registry stub: the tag resolves to an index whose child manifest is
# CHILD_DIGEST, so the "running digest is the per-arch manifest" case is
# exercised rather than assumed.
cat > "$WORK/registry" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ghcr.io/diegonmarcos/cloud-cgc-pub-mcp-binaries:latest)
    printf '%s\n' "$REG_CURRENT"
    [ -n "${CHILD_DIGEST:-}" ] && printf '%s\n' "$CHILD_DIGEST"
    ;;
  *) : ;;   # unknown ref: registry says nothing
esac
SH
chmod +x "$WORK/registry"

# Probe stub: prints the TSV the real ssh probe would print.
cat > "$WORK/probe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PROBE_OUTPUT"
SH
chmod +x "$WORK/probe"

run() {
  PROBE_OUTPUT="$1" \
  GHA_CONFIG="$WORK/build-gha.json" \
  SOLUTIONS_DIR="$WORK/sol" \
  DOCKER_REGISTRY="ghcr.io/diegonmarcos" \
  REG_CURRENT="$REG_CURRENT" \
  CHILD_DIGEST="${CHILD_DIGEST:-}" \
  RECONCILE_PROBE_CMD="$WORK/probe" \
  RECONCILE_REGISTRY_CMD="$WORK/registry" \
    bash "$RECONCILE" testvm >"$WORK/out" 2>"$WORK/err"
  rc=$?
}

T=$(printf '\t')

echo "--- Phase 48: ship reconcile ---"

# 1. Fleet current: both containers run exactly what the registry holds.
run "cloud-cgc-pub-mcp${T}${OURS}${T}${REG_CURRENT}
cloud-cgc-pvt-mcp${T}${OURS}${T}${REG_CURRENT}
postgres${T}docker.io/library/postgres:16${T}sha256:deadbeef"
ck "in-sync fleet exits 0"                 "$rc" "0"
ck "in-sync fleet names nothing"           "$(grep -c drift "$WORK/out")" "0"
ck "upstream image is not our drift"       "$(grep -c 'infra-dat_storage' "$WORK/out")" "0"

# 2. THE LIVE CASUALTY. Registry moved, the VM did not. This is the case that
#    was invisible before: the run list was green, obs_health_drift said "ok",
#    and the service was four commits behind.
run "cloud-cgc-pub-mcp${T}${OURS}${T}${VM_STALE}
cloud-cgc-pvt-mcp${T}${OURS}${T}${VM_STALE}
postgres${T}docker.io/library/postgres:16${T}sha256:deadbeef"
ck "deployed-behind fleet exits 1"         "$rc" "1"
ck "names the drifted service"             "$(grep -c 'user-ai_cloud-cgc-pub-mcp.*drift' "$WORK/out")" "2"
ck "does not name the current service"     "$(grep -c 'infra-dat_storage' "$WORK/out")" "0"
ck "reports the running digest"            "$(grep -c "$VM_STALE" "$WORK/out")" "2"

# 3. Multi-arch: the VM recorded the per-arch child manifest, not the index.
#    A naive index-only compare calls this drift and would re-ship a correct
#    arm64 deploy on every single reconcile — an infinite ship loop on the
#    shared WG runner, which is strictly worse than the bug being fixed.
CHILD_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
run "cloud-cgc-pub-mcp${T}${OURS}${T}${CHILD_DIGEST}
cloud-cgc-pvt-mcp${T}${OURS}${T}${CHILD_DIGEST}"
ck "per-arch child digest is in-sync"      "$rc" "0"
CHILD_DIGEST=""

# 4. A dead probe must never read as a clean fleet.
run ""
ck "empty probe is undecidable, not green" "$rc" "2"
ck "says so out loud"                      "$(grep -c '::error::.*probe returned nothing' "$WORK/err")" "1"

# 5. A silent registry must never read as in-sync either.
run "cloud-cgc-pub-mcp${T}ghcr.io/diegonmarcos/unknown-service:latest${T}${VM_STALE}"
ck "silent registry is undecidable"        "$rc" "2"

# 6. Declared but not running: reported as `absent`, never as `drift`, because
#    the workflow re-ships `drift` only and nine services read absent on the
#    real fleet for reasons that are not #354.
run "cloud-cgc-pub-mcp${T}${OURS}${T}${REG_CURRENT}"
ck "missing container classed absent"      "$(grep -c "absent${T}cloud-cgc-pvt-mcp" "$WORK/out")" "1"
ck "absent is not classed drift"           "$(grep -c "drift" "$WORK/out")" "0"

# 7. An image built on the VM and never pushed has no RepoDigest. Calling that
#    in-sync would hide exactly the state a failed push leaves behind.
run "cloud-cgc-pub-mcp${T}${OURS}${T}
cloud-cgc-pvt-mcp${T}${OURS}${T}${REG_CURRENT}"
ck "digest-less image classed unpublished" "$(grep -c "unpublished" "$WORK/out")" "1"


# ── The re-ship selector: the half that actually re-queues the lost deploy ──
RESHIP="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-reconcile-reship.sh"
[ -f "$RESHIP" ] || { echo "FAIL: $RESHIP missing"; exit 1; }

cat > "$WORK/reship.json" <<'JSON'
{ "reship_classes": ["drift"], "max_reships_per_run": 2 }
JSON

reship() { printf '%s\n' "$1" | RESHIP_CONFIG="$WORK/reship.json" bash "$RESHIP" 2>"$WORK/rerr"; }

# One service, two containers, one image — a single stale deploy reports twice
# and must be dispatched ONCE. Shipping it twice would take two turns of the WG
# lock to do one service's work.
out="$(reship "oci-apps${T}user-ai_cloud-cgc-pub-mcp${T}drift${T}cloud-cgc-pub-mcp
oci-apps${T}user-ai_cloud-cgc-pub-mcp${T}drift${T}cloud-cgc-pvt-mcp")"
ck "duplicate findings collapse to one dir" "$out" "user-ai_cloud-cgc-pub-mcp"

# absent is reported, never dispatched — see ship-reconcile.json for why.
out="$(reship "oci-apps${T}infra-obs_dagu${T}absent${T}dagu")"
ck "absent class is not dispatched"         "$out" ""
ck "absent class is still reported"         "$(grep -c 'absent: 1 finding' "$WORK/rerr")" "1"

# The cap is the #179 guard: an uncapped reconcile finding 40 drifted services
# would hold the fleet's single deploy lock for hours and evict every deploy
# behind it, which is the outage it is supposed to be repairing.
out="$(reship "v${T}svc-a${T}drift${T}c
v${T}svc-b${T}drift${T}c
v${T}svc-c${T}drift${T}c
v${T}svc-d${T}drift${T}c")"
ck "cap bounds one run's lock hold"         "$out" "svc-a,svc-b"
ck "deferred services are named, not lost"  "$(grep -c 'svc-c' "$WORK/rerr")" "1"
ck "says the cap applied"                   "$(grep -c '::warning::4 services are behind' "$WORK/rerr")" "1"

# A deleted or unreadable config must stop the re-ship, not fall back to
# built-in bounds — a cap nothing notices the loss of is not a cap.
out="$(printf '%s\n' "v${T}svc-a${T}drift${T}c" | RESHIP_CONFIG="$WORK/nope.json" bash "$RESHIP" 2>"$WORK/rerr")"
ck "missing config dispatches nothing"      "$out" ""
ck "missing config says so"                 "$(grep -c '::error::.*refusing to guess' "$WORK/rerr")" "1"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
