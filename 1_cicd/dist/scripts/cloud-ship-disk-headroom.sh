#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloud-ship-disk-headroom.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# cloud-ship-disk-headroom.sh -- refuse to start a deploy on a VM that has no room for it.
#
# A ship pulls a fresh image for most services before it recreates a container. On
# oci-apps (144 GB root, 65 GB of volumes) the deploy of Ship 38998754151 ran / to 100%
# (61 MB free): 26 of 59 services failed with "No space left on device" and compose
# left google-workspace-mcp half-recreated. Failing halfway is the worst outcome, so the
# check runs BEFORE any container is touched:
#   free >= MIN_FREE_GB             -> proceed
#   free <  MIN_FREE_GB             -> `docker image prune -f` (dangling images only: untagged
#                                      AND unreferenced, never a tagged or in-use image),
#                                      then re-measure
#   still < MIN_FREE_GB             -> return 1: the caller aborts the ship, nothing touched
# If the VM cannot be measured (ssh down, odd output) the guard warns and lets the ship go
# on, exactly as before -- it must never turn a transport blip into a refused deploy.
#
# Usage:  ship_disk_headroom_guard <vm> [min_free_gb=5]
# Needs `log` / `log_error` (cloud-ship-lib.sh) and, optionally, $SSH_OPTS.
# Env:    SHIP_MIN_FREE_GB overrides the default; 0 disables the guard.

# The big per-VM floor protects a FULL ship; a scoped ship of a few services needs a few hundred MB
# and must not be refused by it. $1 = services about to ship, $2 = the VM's declared floor (may be empty).
# Echoes the floor to apply: the VM floor from SHIP_FULL_MIN_SERVICES (default 8) services up, else 5.
ship_effective_floor() {
  local n="${1:-0}" vmfloor="${2:-}" full="${SHIP_FULL_MIN_SERVICES:-8}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$full" in ''|*[!0-9]*) full=8 ;; esac
  case "$vmfloor" in ''|*[!0-9]*) vmfloor=5 ;; esac
  if [ "$n" -ge "$full" ]; then echo "$vmfloor"; else echo 5; fi
}

_ship_free_gb() { # $1 = vm  -> integer GB free on / of that VM, or empty
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=20 "$1" \
    "df -Pk / | awk 'NR==2{printf \"%d\", \$4/1048576}'" 2>/dev/null
}

ship_disk_headroom_guard() {
  local vm="$1" min="${2:-${SHIP_MIN_FREE_GB:-5}}" free
  case "$min" in ''|*[!0-9]*) min=5 ;; esac
  [ "$min" -eq 0 ] && { log "disk headroom guard disabled (SHIP_MIN_FREE_GB=0)"; return 0; }
  free="$(_ship_free_gb "$vm")"
  case "$free" in
    ''|*[!0-9]*) log "WARN: could not read free disk on $vm; headroom guard skipped"; return 0 ;;
  esac
  if [ "$free" -ge "$min" ]; then
    log "disk headroom: $vm has ${free} GB free (>= ${min} GB)"
    return 0
  fi
  log "disk headroom: $vm has ${free} GB free (< ${min} GB) -- pruning dangling images"
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=20 "$vm" "docker image prune -f" >/dev/null 2>&1 || true
  free="$(_ship_free_gb "$vm")"
  case "$free" in ''|*[!0-9]*) log "WARN: could not re-read free disk on $vm after the prune; continuing"; return 0 ;; esac
  if [ "$free" -ge "$min" ]; then
    log "disk headroom: $vm has ${free} GB free after the prune (>= ${min} GB)"
    return 0
  fi
  log_error "disk headroom: $vm has only ${free} GB free after the prune (< ${min} GB). Refusing to deploy before touching any container -- free space on $vm (see the disk-janitor / volumes) or grow its root, then re-run. Override with SHIP_MIN_FREE_GB."
  return 1
}

# ── Clean up after the deploy: drop the images this ship REPLACED ───────────────────────────
# `docker image prune -f` only removes untagged layers. A redeploy leaves the previous
# version of every service's image TAGGED (the tag moved, the old image id stayed around
# with a different tag or digest), and on oci-apps that was ~8 GB per full ship.
#
# Scope is deliberately narrow: only repositories that a container on the VM runs RIGHT NOW
# (i.e. services this ship just deployed), and only image ids that NO container -- running or
# stopped -- references. `docker rmi` is never forced, so an image that is somehow still in use
# is refused by docker itself. Images of repositories nothing runs (rollback copies of services
# that were never redeployed) are not touched.
#
# The remote script is a single here-doc so the test can run it against a stub `docker`.
SHIP_PRUNE_REPLACED_REMOTE='
set -u
used="$(docker ps -aq | xargs -r docker inspect --format "{{.Image}}" 2>/dev/null | sort -u)"
repos="$(docker ps -a --format "{{.Image}}" | sed -E "s/@sha256:.*//; s/:[^/]*\$//" | sort -u)"
removed=0
for repo in $repos; do
  docker image ls --no-trunc --filter "reference=$repo" --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null | while read -r ref id; do
    case "$ref" in *"<none>"*) continue ;; esac
    printf "%s\n" "$used" | grep -qxF "$id" && continue
    if docker rmi "$ref" >/dev/null 2>&1; then echo "removed $ref"; fi
  done
done
'

ship_prune_replaced_images() { # $1 = vm
  local vm="$1" out
  # shellcheck disable=SC2086
  out="$(ssh ${SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=20 "$vm" "bash -s" <<< "$SHIP_PRUNE_REPLACED_REMOTE" 2>/dev/null)" || {
    log "WARN: could not prune replaced images on $vm (ssh); disk is left for the disk-janitor"; return 0; }
  log "prune replaced images on $vm: $(printf '%s\n' "$out" | grep -c '^removed ') image tag(s) removed"
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /'
  return 0
}
