#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ ship.sh — Portable ship orchestrator                            ║
# ║                                                                  ║
# ║ Detects changed services, resolves VM targets, ships in          ║
# ║ parallel. Pure POSIX — works from GHA, Dagu, CLI, or any        ║
# ║ runner that has: jq, git, ssh, bash (for build.sh).              ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   ship.sh                          # auto-detect from git diff   ║
# ║   ship.sh --vm gcp-proxy           # all services on a VM        ║
# ║   ship.sh --services caddy,ntfy    # specific services            ║
# ║   ship.sh --vm oci-apps --services code-server                   ║
# ║   ship.sh --all                    # everything                   ║
# ║                                                                  ║
# ║ Environment:                                                     ║
# ║   REPO_ROOT         Override repo root (default: git toplevel)   ║
# ║   TRACE_DIR         Where to write trace JSON (default: auto)    ║
# ║   SHIP_PARALLEL     Max parallel services per VM (default: auto) ║
# ║   CLOUD_BUILDER     Use cloud-builder container (default: false) ║
# ║   SSH_KEY,SSH_HOST,SSH_USER,SSH_ALIAS  — per-VM SSH (for CI)     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -u

# ── Helpers ────────────────────────────────────────────────────
log()      { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
log_err()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

# ── Parse arguments ────────────────────────────────────────────
ARG_VM=""
ARG_SERVICES=""
ARG_ALL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --vm)       ARG_VM="$2";       shift 2 ;;
    --services) ARG_SERVICES="$2"; shift 2 ;;
    --all)      ARG_ALL=true;      shift ;;
    --help|-h)
      sed -n '/^# ║ Usage/,/^# ╚/p' "$0" | sed 's/^# ║ //;s/ *║$//;/^# ╚/d'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── Resolve repo root ─────────────────────────────────────────
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT" || die "Cannot cd to $REPO_ROOT"

# ── Resolve cloud-builder image from unix master ──────────────
# Source of truth: III_unix/cb_containers-builders/build.json (.images key).
# Never paste the literal — it drifts when unix renames the image.
resolve_builder_image() {
  _master="$REPO_ROOT/III_unix/cb_containers-builders/build.json"
  [ -f "$_master" ] || die "III_unix/cb_containers-builders/build.json not found — run 'git submodule update --init III_unix'"
  _ghcr=$(jq -r '.images["cloud-builder-x-deb-nixhm"].ghcr // empty' "$_master" 2>/dev/null)
  [ -n "$_ghcr" ] && [ "$_ghcr" != "null" ] || die "No .images['cloud-builder-x-deb-nixhm'].ghcr in $_master"
  printf '%s:latest' "$_ghcr"
}

# 2026-04-27 migrated: cloud-data-gha-config.json -> build-gha.json
GHA_CONFIG=""
for _p in \
    "/app/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/build-gha.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/build-gha.json"; do
    [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
done
if [ -z "$GHA_CONFIG" ]; then
    # Fallback: extract _gha slice from consolidated.
    _CONS_FOR_GHA=""
    for _p in \
        "/app/_cloud-data-consolidated.json" \
        "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/_cloud-data-consolidated.json" \
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
            "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/z_archive/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data/cloud-data-gha-config.json" \
            "${CLOUD_ROOT:-$REPO_ROOT}/cloud-data-gha-config.json"; do
            [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
        done
    fi
fi
[ -n "$GHA_CONFIG" ] || die "build-gha.json (or legacy fallbacks) not found"

SCRIPTS_DIR=".github/workflows/scripts"

# ══════════════════════════════════════════════════════════════════
# PHASE 1: DETECT — which VMs and services need shipping
# ══════════════════════════════════════════════════════════════════
detect_changes() {
  log "Detecting changes..."

  # Determine CHANGED_DIRS and VM_FILTER from arguments
  CHANGED_DIRS=""
  VM_FILTER=""

  if [ "$ARG_ALL" = true ]; then
    # Ship everything
    CHANGED_DIRS=""
    VM_FILTER=""
  elif [ -n "$ARG_SERVICES" ]; then
    # Specific services (comma or space separated)
    CHANGED_DIRS=$(printf '%s' "$ARG_SERVICES" | tr ',' ' ')
    VM_FILTER="$ARG_VM"  # may be empty
  elif [ -n "$ARG_VM" ]; then
    # Specific VM, all its services
    CHANGED_DIRS=""
    VM_FILTER="$ARG_VM"
  else
    # Auto-detect from git diff (push trigger)
    if git rev-parse HEAD~1 >/dev/null 2>&1; then
      CHANGED_DIRS=$(git diff --name-only HEAD~1 HEAD -- a_solutions/*/src/ 2>/dev/null \
        | awk -F/ '{print $2}' | sort -u | tr '\n' ' ')
    fi

    if [ -z "$CHANGED_DIRS" ]; then
      log "No service changes detected in git diff — nothing to ship"
      return 1
    fi
  fi

  # Build VM list with their changed_dirs using jq
  VM_TARGETS=$(jq -r \
    --arg changed "$CHANGED_DIRS" \
    --arg vm_filter "$VM_FILTER" \
    '
    ($changed | split(" ") | map(select(. != ""))) as $changed_list |
    .services | to_entries
    | group_by(.value.vm)
    | map({
        vm: .[0].value.vm,
        changed: (
          [.[] | .value.dir] as $all_dirs |
          if ($changed_list | length) == 0 then
            ""
          else
            [$changed_list[] | select(. as $d | $all_dirs | any(. == $d))] | join(" ")
          end
        )
      })
    | map(select(
        ($vm_filter == "" or .vm == $vm_filter) and
        (($changed_list | length) == 0 or (.changed | length) > 0)
      ))
    | .[]
    | .vm + "|" + .changed
    ' "$GHA_CONFIG")

  if [ -z "$VM_TARGETS" ]; then
    log "No VMs to ship to"
    return 1
  fi

  VM_COUNT=$(printf '%s\n' "$VM_TARGETS" | wc -l)
  log "Shipping to $VM_COUNT VM(s): $(printf '%s\n' "$VM_TARGETS" | cut -d'|' -f1 | tr '\n' ' ')"
  return 0
}

# ══════════════════════════════════════════════════════════════════
# PHASE 2: SHIP — deploy services to each VM (parallel across VMs)
# ══════════════════════════════════════════════════════════════════
ship_vm() {
  _vm="$1"
  _changed_dirs="$2"

  log "── Ship → $_vm ──"

  # cloud-builder-ship.sh reads CHANGED_DIRS from env
  export CHANGED_DIRS="$_changed_dirs"

  # If SSH_KEY/SSH_HOST/SSH_USER are set (CI), cloud-builder-secrets.sh uses them.
  # If not (local/Dagu), SSH config from ~/.ssh/config is used directly.

  if [ "${CLOUD_BUILDER:-}" = "true" ]; then
    # Run inside cloud-builder container (GHA / CI)
    _trace_dir="${TRACE_DIR:-$(mktemp -d)}"
    mkdir -p "$_trace_dir"
    _builder_image=$(resolve_builder_image)

    docker run --rm \
      -v "$_trace_dir:/traces" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e TRACE_DIR=/traces \
      -e CHANGED_DIRS="$_changed_dirs" \
      -e SSH_KEY="${SSH_KEY:-}" \
      -e SSH_HOST="${SSH_HOST:-}" \
      -e SSH_USER="${SSH_USER:-}" \
      -e SSH_ALIAS="$_vm" \
      -e SOPS_AGE_KEY="${SOPS_AGE_KEY:-}" \
      -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
      -e GITHUB_ACTOR="${GITHUB_ACTOR:-}" \
      -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
      -e GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-manual}" \
      -e GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-diegonmarcos/cloud}" \
      -e GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}" \
      -e GITHUB_SHA="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}" \
      "$_builder_image" \
      bash -c 'mkdir -p ~/.ssh && ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null && git clone --depth 2 --recurse-submodules https://github.com/$GITHUB_REPOSITORY.git /workspace && cd /workspace && git submodule update --remote && bash .github/workflows/scripts/cloud-ship-ci-builder.sh ship $SSH_ALIAS 2>&1'
  else
    # Run directly (local / Dagu / any runner with nix+ssh)
    bash "$SCRIPTS_DIR/cloud-ship-ci-builder-dispatch.sh" "$_vm"
  fi
}

ship_all_vms() {
  _pids=""
  _vms_ok=0
  _vms_fail=0
  _results_dir=$(mktemp -d)

  printf '%s\n' "$VM_TARGETS" | while IFS='|' read -r _vm _changed; do
    (
      if ship_vm "$_vm" "$_changed"; then
        echo "ok" > "$_results_dir/$_vm"
      else
        echo "fail" > "$_results_dir/$_vm"
      fi
    ) &
    _pids="$_pids $!"
  done

  # Wait for all background jobs
  _exit=0
  for _pid in $_pids; do
    wait "$_pid" 2>/dev/null || _exit=1
  done

  # Collect results
  printf '%s\n' "$VM_TARGETS" | while IFS='|' read -r _vm _changed; do
    _st=$(cat "$_results_dir/$_vm" 2>/dev/null || echo "fail")
    case "$_st" in
      ok)   _vms_ok=$((_vms_ok + 1));   log "  $_vm: OK" ;;
      *)    _vms_fail=$((_vms_fail + 1)); log "  $_vm: FAIL" ;;
    esac
  done

  rm -rf "$_results_dir"
  return $_exit
}

# ══════════════════════════════════════════════════════════════════
# PHASE 3: TRACES — collect and push (optional)
# ══════════════════════════════════════════════════════════════════
collect_traces() {
  _trace_dir="${TRACE_DIR:-$REPO_ROOT/1_configs/dist/reports/traces-gha}"
  _cloud_data_key="${CLOUD_DATA_DEPLOY_KEY:-}"

  # If no deploy key, traces stay local (CLI/Dagu mode)
  if [ -z "$_cloud_data_key" ]; then
    log "Traces written to $_trace_dir (no CLOUD_DATA_DEPLOY_KEY — skipping push)"
    return 0
  fi

  # Find trace files
  _traces=""
  for _f in "$_trace_dir"/*.json; do
    [ -f "$_f" ] && _traces="$_traces $_f"
  done
  [ -z "$_traces" ] && { log "No trace files to push"; return 0; }

  log "Pushing traces to cloud-data..."

  # Setup SSH for cloud-data repo
  mkdir -p ~/.ssh
  printf '%s\n' "$_cloud_data_key" > ~/.ssh/cloud_data_key
  chmod 600 ~/.ssh/cloud_data_key
  ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
  GIT_SSH_COMMAND="ssh -i $HOME/.ssh/cloud_data_key -o StrictHostKeyChecking=no"
  export GIT_SSH_COMMAND

  _tmp=$(mktemp -d)
  git clone --depth 1 git@github.com:diegonmarcos/cloud-data.git "$_tmp/cloud-data"
  cd "$_tmp/cloud-data"
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  mkdir -p reports/traces-gha
  for _f in $_traces; do
    [ -f "$_f" ] || continue
    _vm=$(jq -r '.vm' "$_f")
    _target="reports/traces-gha/${_vm}.json"
    if [ -f "$_target" ]; then
      jq --slurpfile new "$_f" '. + $new | .[-200:]' "$_target" > "${_target}.tmp" \
        && mv "${_target}.tmp" "$_target"
    else
      jq -s '.' "$_f" > "$_target"
    fi
  done

  git add reports/traces-gha/
  git diff --cached --quiet && { log "No trace changes"; cd "$REPO_ROOT"; rm -rf "$_tmp"; return 0; }
  git commit -m "auto: traces [skip ci]"
  _i=0
  while [ $_i -lt 3 ]; do
    _i=$((_i + 1))
    git push origin main && break
    log "Push attempt $_i failed — pulling and retrying..."
    git pull --rebase origin main 2>/dev/null || true
  done

  cd "$REPO_ROOT"
  rm -rf "$_tmp"
  log "Traces pushed"
}

# ══════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════
SHIP_START=$(date +%s)

detect_changes || exit 0

echo ""
echo "═══════════════════════════════════════════════"
echo "  Ship — $(printf '%s\n' "$VM_TARGETS" | wc -l) VM(s)"
echo "═══════════════════════════════════════════════"
echo ""

ship_all_vms
_ship_exit=$?

collect_traces

_dur=$(( $(date +%s) - SHIP_START ))
log "Done in ${_dur}s (exit $_ship_exit)"
exit $_ship_exit
