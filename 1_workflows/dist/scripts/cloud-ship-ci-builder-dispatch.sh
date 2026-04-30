#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-ci-builder-dispatch.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ CI/CD dispatch — routes to container or HM engine                ║
# ║                                                                  ║
# ║ Usage: dispatch.sh {ship|ship-hm} <vm-alias> [service-filter]   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -u

# NOTE: bash's ${var:?msg} parser terminates the message at the FIRST `}`.
# Embedding `{ship|ship-hm}` inside the message causes premature termination,
# leaving CMD with the trailing literal " <vm>}" appended (and the ship-hm
# routing below silently never matches). Use an explicit guard instead.
if [ "$#" -lt 1 ]; then
    echo "Usage: dispatch.sh ship-or-ship-hm vm-alias [service-filter]" >&2
    exit 1
fi
CMD="$1"
shift

# ── Route ship-hm to HM engine ──
if [ "$CMD" = "ship-hm" ]; then
    REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    exec bash "$REPO_ROOT/.github/workflows/scripts/cloud-ship-orchestrate-homemanager.sh" "$@"
fi

# ── Container ship engine (existing logic) ──
VM="${1:?Usage: dispatch.sh ship <vm> [service-filter]}"
FILTER="${2:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# ── Source shared lib (log, log_error, helpers) ──
# Must happen before first `log` call below. Lib lives next to this script
# in dist/scripts/ (deployed via build.sh).
_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud-ship-lib.sh
. "$_DISPATCH_DIR/cloud-ship-lib.sh"

# ── Trace collection ─────────────────────────────────────────────
RUN_START=$(date +%s)
TRACE_SERVICES="[]"

# 2026-04-27 migrated: cloud-data-gha-config.json -> build-gha.json
# We accept either the canonical build-gha.json (preferred) or materialise
# the _gha slice from consolidated into a tmpfile (with wg_ip joined from
# .vms[].ssh_alias) so downstream jq filters operating on .vms[VM].
# {wg_ip,host,user,ssh_secret} keep working.
GHA_CONFIG=""
for _p in \
    "/app/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/build-gha.json"; do
    [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
done
if [ -z "$GHA_CONFIG" ]; then
    # Fallback: extract _gha slice from consolidated.
    _CONS_FOR_GHA=""
    for _p in \
        "/app/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/_cloud-data-consolidated.json"; do
        [ -f "$_p" ] && { _CONS_FOR_GHA="$_p"; break; }
    done
    if [ -n "$_CONS_FOR_GHA" ]; then
        GHA_CONFIG="${RUNNER_TEMP:-/tmp}/gha-config.json"
        jq '
          ._gha as $g
          | (.vms | to_entries | map({key: .value.ssh_alias, value: .value.wg_ip}) | from_entries) as $alias_to_wg
          | $g
          | .vms |= with_entries(.value += {wg_ip: ($alias_to_wg[.key] // null)})
        ' "$_CONS_FOR_GHA" > "$GHA_CONFIG"
    else
        for _p in \
            "/app/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data-gha-config.json"; do
            [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
        done
    fi
fi
if [ -z "$GHA_CONFIG" ]; then
  echo "FATAL: build-gha.json (or legacy fallbacks) not found" >&2
  exit 1
fi

# Get services for this VM
SERVICES=$(jq -r --arg vm "$VM" '
  .services | to_entries[]
  | select(.value.vm == $vm)
  | [.value.dir, .key]
  | join("|")
' "$GHA_CONFIG")

if [ -z "$SERVICES" ]; then
  echo "No services found for VM: $VM"
  exit 0
fi

# CHANGED_DIRS: passed from GHA detect job, or empty = ship all (CLI/Dagu)
CHANGED_DIRS="${CHANGED_DIRS:-}"
[ -n "$CHANGED_DIRS" ] && echo "Changed dirs: $CHANGED_DIRS"

TOTAL=$(echo "$SERVICES" | wc -l)
_CORES=$(nproc 2>/dev/null || echo 2)
MAX_PARALLEL="${SHIP_PARALLEL:-$(( _CORES > 1 ? _CORES - 1 : 1 ))}"  # nproc-1, min 1

# ── Pre-establish SSH multiplex master connection ────────────────
# One persistent connection — all parallel services reuse it via ControlPath
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-mux-%r@%h:%p -o ControlPersist=300 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"
ssh $SSH_OPTS -fNM "$VM" 2>/dev/null && log "SSH multiplex master established to $VM" || log "SSH multiplex: $VM unreachable (will retry per-service)"
# Workers must REUSE the master, never race to create one
SSH_OPTS="-o ControlMaster=no -o ControlPath=/tmp/ssh-mux-%r@%h:%p -o ControlPersist=300 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"

# ── Warm declared arch runners (for cross-arch docker builds) ────
# Services with docker.arch != HOST_ARCH need a remote builder (e.g. arm64
# → oci-apps cloud-builder-x). Source of truth: cloud-data-runners.json.
# Export CLOUD_BUILDER_<ARCH>_READY=1 so step_docker skips its live probe.
RUNNERS_JSON=""
for _p in \
    "/app/cloud-data-runners.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/2_configs/dist/cloud-data-runners.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/cloud-data-runners.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data-runners.json"; do
    [ -f "$_p" ] && { RUNNERS_JSON="$_p"; break; }
done
if [ -n "$RUNNERS_JSON" ]; then
    _HOST_ARCH=$(uname -m)
    case "$_HOST_ARCH" in
        x86_64)  _HOST_ARCH_DOCKER="amd64" ;;
        aarch64) _HOST_ARCH_DOCKER="arm64" ;;
        *)       _HOST_ARCH_DOCKER="$_HOST_ARCH" ;;
    esac
    # Collect distinct docker.arch values across matching services
    _ARCHES=$(while IFS='|' read -r dir _; do
        bj="$REPO_ROOT/a_solutions/$dir/build.json"
        [ -f "$bj" ] || continue
        jq -r '.docker.arch // empty' "$bj" 2>/dev/null
    done <<< "$SERVICES" | sort -u)
    for _arch in $_ARCHES; do
        [ "$_arch" = "$_HOST_ARCH_DOCKER" ] && continue
        _type=$(jq -r --arg a "$_arch" '.runners[$a].type // empty' "$RUNNERS_JSON")
        _host=$(jq -r --arg a "$_arch" '.runners[$a].host // empty' "$RUNNERS_JSON")
        [ "$_type" = "ssh" ] || continue
        [ -z "$_host" ] && continue
        if ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh-mux-%r@%h:%p -o ControlPersist=300 -fNM "$_host" 2>/dev/null; then
            log "Runner for arch=$_arch warmed: $_host"
            export "CLOUD_BUILDER_$(echo "$_arch" | tr '[:lower:]' '[:upper:]')_READY=1"
        else
            log_error "Runner for arch=$_arch UNREACHABLE (host=$_host). ship for arm64 services will fail."
        fi
    done
fi

# ── Update cloud-data submodule ONCE (locked, before parallel workers) ──
# Per-service parallel updates race on .git/modules/cloud-data/config lock
# and each one prints every unstaged file — huge log spam + "File exists"
# lock errors. Run serially here; per-service nix step is gated by the
# CLOUD_DATA_PRESTAGED_BY_CI flag set below.
if [ -f "$REPO_ROOT/.gitmodules" ] && [ -d "$REPO_ROOT/2_configs/dist" ]; then
  _CD_LOCK=/tmp/cloud-data-submodule.lock
  (
    flock -w 60 9 || { log_error "Could not acquire cloud-data submodule lock after 60s"; exit 1; }
    log "Updating 2_configs/dist submodule (once, serialized for parallel ship jobs)"
    if ! git -C "$REPO_ROOT" -c submodule."2_configs/dist".update=checkout \
         submodule update --remote --init --force 2_configs/dist 2>&1 \
         | while IFS= read -r line; do log "  $line"; done; then
      log "WARN: 2_configs/dist update failed — ship will use the pinned commit (may be stale)"
    fi
  ) 9>"$_CD_LOCK"
fi

# ── Pre-stage cloud-data into all services' src/ (before parallel jobs) ──
# Parallel builds race on git index — stage everything once, serially.
# Two passes: 1) resolve symlinks to real files, 2) copy for include_cloud_data
CLOUD_DATA_DIR="$REPO_ROOT/2_configs/dist"
CLOUD_DATA_PRESTAGED=""
if [ -d "$CLOUD_DATA_DIR" ]; then
  echo "Pre-staging cloud-data: resolving symlinks + copying flagged services"

  # Pass 1: Resolve external *.json symlinks in ALL services' src/ to real files.
  # Nix flakes can't follow symlinks into submodules — must be real files.
  # Matches any symlink whose target is OUTSIDE the service directory
  # (covers cloud-data-*.json, _cloud-data-*.json, and build-{container}.json).
  # The `case` guard skips intra-service symlinks like build.json → ../build.json.
  while IFS='|' read -r dir name; do
    SRC="$REPO_ROOT/a_solutions/$dir/src"
    SVC_DIR="$REPO_ROOT/a_solutions/$dir"
    [ -d "$SRC" ] || continue
    for f in "$SRC"/*.json; do
      [ -L "$f" ] || continue
      REAL_TARGET=$(readlink -f "$f" 2>/dev/null || true)
      case "$REAL_TARGET" in
        "$SVC_DIR"/*) continue ;;  # intra-service — nix can follow
      esac
      if [ -f "$REAL_TARGET" ]; then
        rm "$f"
        cp "$REAL_TARGET" "$f"
        CLOUD_DATA_PRESTAGED="$CLOUD_DATA_PRESTAGED $f"
      fi
    done
  done <<< "$SERVICES"

  # Pass 2: Copy cloud-data for services with include_cloud_data=true
  while IFS='|' read -r dir name; do
    SVC_DIR="$REPO_ROOT/a_solutions/$dir"
    BUILD_JSON="$SVC_DIR/build.json"
    [ -f "$BUILD_JSON" ] || continue
    INCLUDE=$(node -e "try{const c=require('$BUILD_JSON');process.stdout.write(String(c.build?.include_cloud_data||''))}catch{}" 2>/dev/null)
    [ "$INCLUDE" = "true" ] || continue
    SRC="$SVC_DIR/src"
    [ -d "$SRC" ] || continue
    for f in "$CLOUD_DATA_DIR"/*.json; do
      [ -f "$f" ] || continue
      BASENAME=$(basename "$f")
      TARGET="$SRC/$BASENAME"
      [ -f "$TARGET" ] && continue  # already resolved in pass 1
      cp "$f" "$TARGET"
      CLOUD_DATA_PRESTAGED="$CLOUD_DATA_PRESTAGED $TARGET"
    done
  done <<< "$SERVICES"

  # Single git add for all resolved/copied files — no index race
  if [ -n "$CLOUD_DATA_PRESTAGED" ]; then
    RELS=""
    for t in $CLOUD_DATA_PRESTAGED; do
      RELS="$RELS $(realpath --relative-to="$REPO_ROOT" "$t")"
    done
    git -C "$REPO_ROOT" add $RELS
    echo "Staged $(echo $CLOUD_DATA_PRESTAGED | wc -w) cloud-data files across services"
  fi
  export CLOUD_DATA_PRESTAGED_BY_CI=true
fi

echo "═══════════════════════════════════════════════"
echo "Ship → $VM ($TOTAL services, max $MAX_PARALLEL parallel)"
echo "═══════════════════════════════════════════════"

# ── Per-service worker (runs in background) ──────────────────────
RESULTS_DIR=$(mktemp -d)

ship_one() {
  local dir="$1" name="$2"
  local log_file="$RESULTS_DIR/${name}.log"
  local svc_start
  svc_start=$(date +%s)

  {
    echo "── Ship: $name ($dir) ──"

    BUILD_SH="a_solutions/${dir}/build.sh"
    if [ ! -f "$BUILD_SH" ]; then
      echo "SKIP $name (no build.sh)"
      echo "skip" > "$RESULTS_DIR/${name}.status"
      echo "0" > "$RESULTS_DIR/${name}.dur"
      return 0
    fi

    if bash "$BUILD_SH" ship; then
      echo "OK $name"
      echo "ok" > "$RESULTS_DIR/${name}.status"
    else
      echo "FAIL $name (exit $?)"
      echo "fail" > "$RESULTS_DIR/${name}.status"
    fi
  } 2>&1 | stdbuf -oL sed "s/^/[$name] /" | tee "$log_file"

  echo "$(( $(date +%s) - svc_start ))" > "$RESULTS_DIR/${name}.dur"
}

# ── Launch services in parallel (xargs-based) ────────────────────
SHIP_CMDS=$(mktemp)

while IFS='|' read -r dir name; do
  if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  if [ -n "$CHANGED_DIRS" ] && ! echo "$CHANGED_DIRS" | grep -q "$dir"; then
    echo "SKIP $name (unchanged)"
    echo "skip" > "$RESULTS_DIR/${name}.status"
    echo "0" > "$RESULTS_DIR/${name}.dur"
    continue
  fi

  echo "$dir|$name" >> "$SHIP_CMDS"
done <<< "$SERVICES"

export -f ship_one
export RESULTS_DIR

cat "$SHIP_CMDS" | xargs -P "$MAX_PARALLEL" -I{} bash -c '
  IFS="|" read -r dir name <<< "{}"
  ship_one "$dir" "$name"
'
rm -f "$SHIP_CMDS"

# ── Post-parallel: clean up pre-staged cloud-data files ─────────
if [ -n "${CLOUD_DATA_PRESTAGED:-}" ]; then
  for t in $CLOUD_DATA_PRESTAGED; do
    REL=$(realpath --relative-to="$REPO_ROOT" "$t" 2>/dev/null || true)
    [ -n "$REL" ] && git -C "$REPO_ROOT" reset HEAD "$REL" 2>/dev/null || true
    rm -f "$t"
  done
fi

# ── Collect results ──────────────────────────────────────────────
OK=0; FAIL=0; SKIP=0

while IFS='|' read -r dir name; do
  [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
  status=$(cat "$RESULTS_DIR/${name}.status" 2>/dev/null || echo "fail")
  dur=$(cat "$RESULTS_DIR/${name}.dur" 2>/dev/null || echo "0")
  case "$status" in
    ok)   OK=$((OK + 1)) ;;
    skip) SKIP=$((SKIP + 1)) ;;
    *)    FAIL=$((FAIL + 1)) ;;
  esac
  TRACE_SERVICES=$(jq --arg n "$name" --arg d "$dir" --arg s "$status" --argjson dur "$dur" \
    '. + [{"name":$n,"dir":$d,"status":$s,"duration_s":$dur}]' <<< "$TRACE_SERVICES")
done <<< "$SERVICES"

rm -rf "$RESULTS_DIR"

echo ""
echo "═══════════════════════════════════════════════"
echo "Ship → $VM: $OK ok, $FAIL failed, $SKIP skipped (of $TOTAL)"

# ── Write trace JSON ─────────────────────────────────────────────
# TRACE_DIR env var: set by GHA template (-v mount), fallback for CLI/Dagu
RUN_DUR=$(( $(date +%s) - RUN_START ))
RUN_STATUS="success"; [ "$FAIL" -gt 0 ] && RUN_STATUS="failure"

TRACE_DIR="${TRACE_DIR:-$REPO_ROOT/2_configs/dist/reports/traces-gha}"
mkdir -p "$TRACE_DIR"

jq -n \
  --arg vm "$VM" \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  --arg run_url "https://github.com/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}" \
  --arg sha "${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}" \
  --arg trigger "${GITHUB_EVENT_NAME:-manual}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson dur "$RUN_DUR" \
  --argjson total "$TOTAL" \
  --argjson ok "$OK" \
  --argjson fail "$FAIL" \
  --argjson skip "$SKIP" \
  --arg status "$RUN_STATUS" \
  --argjson services "$TRACE_SERVICES" \
  '{vm:$vm,run_id:$run_id,run_url:$run_url,sha:$sha,trigger:$trigger,ts:$ts,duration_s:$dur,total:$total,ok:$ok,fail:$fail,skip:$skip,status:$status,services:$services}' \
  > "$TRACE_DIR/${VM}.json"

echo "Trace written: $TRACE_DIR/${VM}.json"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
