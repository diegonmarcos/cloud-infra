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

# 4. A dead probe must never read as a clean fleet. The probe says UNREACHABLE
#    on the wire rather than leaving the caller to infer it from empty output,
#    because "the VM would not answer" and "the VM answered, nothing is running"
#    are different facts and collapsing them is how a dead probe starts reading
#    as a healthy fleet.
run "#UNREACHABLE"
ck "unreachable VM yields no in-sync claim" "$(grep -c 'in-sync' "$WORK/out")" "0"
ck "unreachable VM says so out loud"        "$(grep -c '::error::.*did not answer' "$WORK/err")" "1"

# 5. A silent registry must never read as in-sync — but it must not be fatal
#    either. kg-store-binaries and session-memory-binaries are PRIVATE packages
#    that answer 403 to both an anonymous token and this repo's GITHUB_TOKEN, so
#    treating an undecidable image as exit 2 made the scheduled reconcile
#    permanently red. A watchdog that is always red is ignored exactly as fast
#    as one that is always green.
run "cloud-cgc-pub-mcp${T}ghcr.io/diegonmarcos/unknown-service:latest${T}${VM_STALE}"
ck "silent registry is not called in-sync" "$(grep -c 'undecidable' "$WORK/out")" "1"
ck "silent registry is not fatal"          "$rc" "0"
ck "silent registry is not re-shipped"     "$(grep -c 'drift' "$WORK/out")" "0"

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


# 8. containers[] is NOT homogeneous across the fleet: infra-db_postlite's array
#    mixes objects with a bare string, and `.container_name` on a string is a jq
#    RUNTIME error (exit 5) that arrives AFTER jq has already printed the valid
#    names. Under `set -o pipefail` that killed the entire fleet sweep, and with
#    jq's stderr discarded it died having printed nothing — run 35038684236,
#    0.03s, no output, exit 5. One malformed declaration must cost that service,
#    never the other 67.
mkdir -p "$WORK/sol/infra-db_postlite"
cat > "$WORK/sol/infra-db_postlite/build.json" <<'JSON'
{ "containers": [ { "container_name": "postlite-npm" },
                  "a bare string that is not a container object",
                  { "container_name": "postlite-ntfy" } ] }
JSON
cat > "$WORK/gha-mixed.json" <<'JSON'
{
  "vms": { "testvm": { "wg_ip": "10.0.0.99" } },
  "services": {
    "postlite": { "dir": "infra-db_postlite",         "vm": "testvm", "has_docker": true },
    "pubmcp":   { "dir": "user-ai_cloud-cgc-pub-mcp", "vm": "testvm", "has_docker": true }
  }
}
JSON
PROBE_OUTPUT="cloud-cgc-pub-mcp${T}${OURS}${T}${VM_STALE}" GHA_CONFIG="$WORK/gha-mixed.json" SOLUTIONS_DIR="$WORK/sol" DOCKER_REGISTRY="ghcr.io/diegonmarcos" REG_CURRENT="$REG_CURRENT" CHILD_DIGEST="" RECONCILE_PROBE_CMD="$WORK/probe" RECONCILE_REGISTRY_CMD="$WORK/registry"   bash "$RECONCILE" testvm >"$WORK/out" 2>"$WORK/err"
rc=$?
ck "mixed containers[] does not abort the sweep" "$rc" "1"
ck "the healthy service is still reported"       "$(grep -c 'user-ai_cloud-cgc-pub-mcp.*drift' "$WORK/out")" "1"
ck "the mixed service's objects still parse"     "$(grep -c 'postlite-npm' "$WORK/out")" "1"

# 9. A DIGEST-PINNED ref cannot drift: the container runs exactly the digest it
#    was pinned to, and that digest is in the ref. gcp-proxy's caddy runs
#    ghcr.io/diegonmarcos/caddy-l4@sha256:..., and splitting that on the last
#    ':' yielded repo "…/caddy-l4@sha256" and tag "d8309fad…", which the
#    registry refused — the most decidable image on the fleet reported as
#    undecidable. This resolves from the ref with no registry call at all, so
#    the stub below is deliberately never consulted.
PINNED="sha256:d8309fad8a32c393ddf7a258b8dbfc990ea928372284804a08bd071a13df6b7c"
run "cloud-cgc-pub-mcp${T}ghcr.io/diegonmarcos/caddy-l4@${PINNED}${T}${PINNED}"
ck "digest-pinned ref is in-sync"          "$(grep -c 'undecidable' "$WORK/out")" "0"
ck "digest-pinned ref is not drift"        "$(grep -c 'drift' "$WORK/out")" "0"

#    ...and a pinned ref whose RUNNING digest does not match the pin is real
#    drift: the container is not running what it was pinned to.
run "cloud-cgc-pub-mcp${T}ghcr.io/diegonmarcos/caddy-l4@${PINNED}${T}${VM_STALE}"
ck "pin violated is reported as drift"     "$(grep -c 'drift' "$WORK/out")" "1"

# 10. An UNREACHABLE VM is not a clean VM, and it is also not a reason to stop.
#     oci-mail answered normally in run 35039429321 and timed out at exactly
#     ConnectTimeout fifteen minutes later; treating that as fatal blocked the
#     re-ship of drift already found on the three VMs that answered — #354
#     continuing quietly because of a dropped packet.
run "#UNREACHABLE"
ck "unreachable VM is recorded"            "$(grep -c 'unreachable' "$WORK/out")" "1"
ck "unreachable VM emits nothing else"     "$(grep -vc 'unreachable' "$WORK/out")" "0"
ck "unreachable VM is not re-shippable"    "$(grep -c 'drift' "$WORK/out")" "0"

#     ...and a VM that DOES answer with nothing running is a real answer: those
#     containers are absent, not unknown. Collapsing the two is how a dead probe
#     starts reading as a clean fleet.
run ""
ck "reachable-but-empty is not unreachable" "$(grep -c 'unreachable' "$WORK/out")" "0"
ck "reachable-but-empty yields absent"      "$(grep -c 'absent' "$WORK/out")" "3"
ck "reachable-but-empty is not fatal"       "$rc" "0"

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
