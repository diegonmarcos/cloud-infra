#!/usr/bin/env bash
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
