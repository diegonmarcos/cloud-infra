# Step: Activate home-manager on VM
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

# ── Docker socket API helpers ───────────────────────────────────────────
# When docker CLI is missing on the VM (e.g. nix GC'd docker-client),
# fall back to curl against the Docker Engine unix socket.
DOCKER_SOCK="/var/run/docker.sock"

# Build the remote script that runs on the VM via SSH.
# This script auto-detects docker CLI vs socket API and uses the right one.
_build_docker_activate_script() {
    cat <<'REMOTE_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
DOCKER_SOCK="/var/run/docker.sock"
IMAGE="@@IMAGE@@"
TAG="@@TAG@@"
HM_USER="@@HM_USER@@"
FULL_IMAGE="${IMAGE}:${TAG}"

export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# ── Pre-check: Docker daemon running? ──
if [ -S "$DOCKER_SOCK" ]; then
    echo "[hm-docker] Docker socket found"
elif command -v systemctl >/dev/null 2>&1; then
    echo "[hm-docker] Starting Docker daemon..."
    sudo systemctl start docker 2>/dev/null || true
    sleep 2
    if [ ! -S "$DOCKER_SOCK" ]; then
        echo "[hm-docker] ERROR: Docker daemon failed to start"
        exit 1
    fi
else
    echo "[hm-docker] ERROR: Docker socket not found at $DOCKER_SOCK"
    exit 1
fi

# ── Transport detection ──
# A `command -v docker` hit isn't enough — there might be a wrapper that exec's
# a stale docker-real or a now-purged nix-profile target. Probe `docker version`
# to verify the binary chain actually resolves before choosing the CLI path.
if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    USE_CLI=true
    echo "[hm-docker] Transport: docker CLI"
else
    USE_CLI=false
    if command -v curl >/dev/null 2>&1; then
        echo "[hm-docker] Transport: socket API (docker CLI missing or broken)"
    else
        echo "[hm-docker] ERROR: neither working docker CLI nor curl+socket available"
        exit 1
    fi
fi

# ── Helper: docker API via socket ──
dock_api() {
    _method="$1"; _endpoint="$2"; shift 2
    curl -sf --unix-socket "$DOCKER_SOCK" -X "$_method" "http://localhost$_endpoint" "$@"
}

# ── Step 1: Pull image ──
echo "[hm-docker] Pulling $FULL_IMAGE"
if [ "$USE_CLI" = true ]; then
    docker pull "$FULL_IMAGE" 2>&1 | tail -3
else
    HTTP_CODE=$(curl -s --unix-socket "$DOCKER_SOCK" -o /tmp/.hm-pull-out -w '%{http_code}' \
        -X POST "http://localhost/images/create?fromImage=${IMAGE}&tag=${TAG}")
    if [ "$HTTP_CODE" -ge 400 ]; then
        echo "[hm-docker] Pull failed (HTTP $HTTP_CODE):"
        cat /tmp/.hm-pull-out 2>/dev/null
        rm -f /tmp/.hm-pull-out
        exit 1
    fi
    tail -3 /tmp/.hm-pull-out 2>/dev/null || true
    rm -f /tmp/.hm-pull-out
    echo "[hm-docker] Pull complete"
fi

# ── Step 2: Clean up any previous hm-activate container ──
# Kill EVERY hm-activate-* container, not just the same-PID one. Orphans
# from prior failed/interrupted ships otherwise race the new one for
# /nix/store writes and corrupt the cp -aR (oci-mail incident 2026-05-06).
CONTAINER_NAME="hm-activate-$$"
if [ "$USE_CLI" = true ]; then
    OLD_IDS=$(docker ps -a --filter name=hm-activate --format '{{.ID}}' 2>/dev/null || true)
    for _cid in $OLD_IDS; do
        docker rm -f "$_cid" 2>/dev/null || true
    done
else
    OLD_IDS=$(dock_api GET '/containers/json?all=true&filters={"name":["hm-activate"]}' 2>/dev/null \
        | grep -o '"Id":"[^"]*"' | sed 's/"Id":"//;s/"//' || true)
    for _cid in $OLD_IDS; do
        dock_api POST "/containers/$_cid/stop" 2>/dev/null || true
        dock_api DELETE "/containers/$_cid" 2>/dev/null || true
    done
fi

# ── Step 3: Run activation container ──
echo "[hm-docker] Running activation container"
if [ "$USE_CLI" = true ]; then
    docker run --rm --name "$CONTAINER_NAME" -v /:/host -e HM_HOST_ROOT=/host "$FULL_IMAGE" 2>&1
else
    CREATE_BODY="{
        \"Image\": \"${FULL_IMAGE}\",
        \"Env\": [\"HM_HOST_ROOT=/host\"],
        \"HostConfig\": {
            \"Binds\": [\"/:/host\"]
        }
    }"
    CREATE_RESP=$(dock_api POST "/containers/create?name=${CONTAINER_NAME}" \
        -H "Content-Type: application/json" -d "$CREATE_BODY" 2>&1)
    CID=$(printf '%s' "$CREATE_RESP" | grep -o '"Id":"[^"]*"' | head -1 | sed 's/"Id":"//;s/"//')
    if [ -z "$CID" ]; then
        echo "[hm-docker] ERROR: container create failed: $CREATE_RESP"
        exit 1
    fi
    echo "[hm-docker] Container created: ${CID:0:12}"

    dock_api POST "/containers/$CID/start" >/dev/null 2>&1
    echo "[hm-docker] Container started"

    WAIT_RESP=$(dock_api POST "/containers/$CID/wait" 2>&1 || true)
    WAIT_CODE=$(printf '%s' "$WAIT_RESP" | grep -o '"StatusCode":[0-9]*' | sed 's/"StatusCode"://')
    WAIT_CODE="${WAIT_CODE:-999}"

    echo "[hm-docker] Container logs:"
    curl -s --unix-socket "$DOCKER_SOCK" "http://localhost/containers/$CID/logs?stdout=true&stderr=true" \
        2>/dev/null | tr -d '\000-\010' || true

    dock_api DELETE "/containers/$CID?force=true" 2>/dev/null || true

    if [ "$WAIT_CODE" -ne 0 ]; then
        echo "[hm-docker] ERROR: activation container exited with code $WAIT_CODE"
        exit 1
    fi
fi

# ── Step 3.5: Reclaim image overlay BEFORE native activate ──
# The activation container has finished cp'ing the closure to host's /nix/store.
# Native activate (step 5) only needs files on host — never reaches back into
# the image's overlay. Removing the image NOW (before nix-build /tmp/* runs)
# frees ~6 GB right when nix-build wants peak transient room. Drops cumulative
# peak from ~11 GB to ~8 GB.
if [ "$USE_CLI" = true ]; then
    docker rmi -f "$FULL_IMAGE" >/dev/null 2>&1 \
      && echo "[hm-docker] Reclaimed image overlay (pre-activate): $FULL_IMAGE" \
      || echo "[hm-docker] Image rmi non-fatal (still referenced)"
else
    IMG_ID=$(dock_api GET "/images/json?filters=%7B%22reference%22%3A%5B%22${IMAGE}%22%5D%7D" 2>/dev/null \
        | grep -o '"Id":"[^"]*"' | head -1 | sed 's/"Id":"//;s/"//')
    [ -n "$IMG_ID" ] && dock_api DELETE "/images/${IMG_ID}?force=true" >/dev/null 2>&1 \
      && echo "[hm-docker] Reclaimed image overlay (pre-activate, socket): $IMG_ID" \
      || true
fi

# ── Step 4: Register nix paths in host DB (native, not container) ──
echo "[hm-docker] Registering nix paths (native)..."
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
if [ -f /tmp/.hm-nix-db-dump.txt ]; then
    sudo nix-store --load-db < /tmp/.hm-nix-db-dump.txt 2>&1 | tail -5
    echo "[hm-docker] Paths registered via --load-db"
    sudo rm -f /tmp/.hm-nix-db-dump.txt
else
    echo "[hm-docker] WARN: no DB dump found — paths may not be registered"
fi

# ── Step 4.5: Re-own /nix to HM_USER (post-cp, pre-activate) ──
# The activation container ran cp -aR /nix/store → /host/nix/store as root,
# preserving image-internal ownership (root). When sudo -u $HM_USER runs
# `activate` next, nix-env tries to create a lock file inside /nix/store
# and fails with EACCES on the freshly-cp'd root-owned dir entries.
# Determinate-Nix multi-user mode would normally route writes through the
# nix-daemon as root, but on freshly-bootstrapped GCP VMs (and any VM where
# nix-daemon is disabled) the user-side write path needs ownership.
# Idempotent: chown -R is a no-op once converged.
echo "[hm-docker] Reclaiming /nix ownership for $HM_USER"
sudo chown -R "$HM_USER:$HM_USER" /nix 2>/dev/null || true

# ── Step 5: Activate generation ──
# HM's activate script does `nix-build --quiet --expr '{}'` as a sanity check
# (line 170 of generation/activate). sudo -u strips PATH; nix-build is normally
# at /nix/var/nix/profiles/default/bin (multi-user) or ~/.nix-profile/bin
# (single-user). On VMs where the previous generation never linked nix into
# the user's profile (oci-mail, 2026-05-05), the bare default PATH lacks
# nix-build → activate dies "command not found". Resolve nix-build's actual
# directory at runtime and prepend it to the activation PATH.
echo "[hm-docker] Activating generation"
ACTIVATE=$(cat /tmp/.hm-activation-path 2>/dev/null)
if [ -n "$ACTIVATE" ] && [ -x "$ACTIVATE/activate" ]; then
    rm -f "/home/$HM_USER/.local/bin/docker" 2>/dev/null
    NIX_BIN_DIR=""
    for _candidate in /nix/var/nix/profiles/default/bin /home/$HM_USER/.nix-profile/bin /nix/var/nix/profiles/per-user/$HM_USER/profile/bin; do
        if [ -x "$_candidate/nix-build" ]; then
            NIX_BIN_DIR="$_candidate"
            break
        fi
    done
    if [ -z "$NIX_BIN_DIR" ]; then
        # Fallback: scan /nix/store for the newest nix-2.* package.
        NIX_BIN_DIR=$(ls -1d /nix/store/*-nix-2.*/bin 2>/dev/null | grep -v -- '-man' | sort -V | tail -1)
    fi
    if [ -n "$NIX_BIN_DIR" ] && [ -x "$NIX_BIN_DIR/nix-build" ]; then
        echo "[hm-docker] Using nix-build from $NIX_BIN_DIR"
        sudo -u "$HM_USER" HOME="/home/$HM_USER" USER="$HM_USER" \
            PATH="$NIX_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            "$ACTIVATE/activate" 2>&1
    else
        echo "[hm-docker] WARN: no nix-build found — activation may fail"
        sudo -u "$HM_USER" HOME="/home/$HM_USER" USER="$HM_USER" "$ACTIVATE/activate" 2>&1
    fi
    echo "[hm-docker] Generation activated successfully"
    # Image already reclaimed at step 3.5 (before native nix-build). Nothing to do here.
else
    echo "[hm-docker] ERROR: activation path not found or not executable: $ACTIVATE"
    exit 1
fi
REMOTE_SCRIPT_EOF
}

step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
        # ── Docker delivery: pull image on VM, run activation container ──
        [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set"; return 1; }
        log "Docker delivery: activating $HM_IMAGE on $DEPLOY_HOST"

        # ── Pre-flight: ensure VM has disk headroom for activation ──
        # HM activation is a 3-stage pipeline that all writes to the VM's /:
        #   1. docker pull HM image (~2-5GB compressed → overlay2)
        #   2. activation container cp -aR /nix/store → host (~5-7GB)
        #   3. nix-build derivations in /tmp/nix-build-* (~1-3GB transient)
        # Cumulative peak: ~10-15GB headroom required. Without it the
        # activation hits ENOSPC at nix-build mkdir (incident 2026-05-02
        # on oci-mail: 7.8GB free → activation peaks at 100% disk usage →
        # error: creating directory ... No space left on device).
        # Fix: pre-flight prune docker + truncate runaway logs + journal
        # vacuum before any pull/cp/activate runs. Data-driven threshold:
        #   build.json:.vm.disk.activation_min_free_gb (default 10).
        # Single source of truth: 1_workflows/src/data/hm-config.json
        # ALSO read by b_infra/_shared/vm-pilot/src/modules/protection/disk-ballast.nix
        # via symlinked b_infra/_shared/modules/hm-config.json.
        HM_CONFIG_FILE="$STEPS_DIR/../data/hm-config.json"
        MIN_FREE_GB=$(jq -r '.min_size_ballast_file_gb' "$HM_CONFIG_FILE" 2>/dev/null)
        : "${MIN_FREE_GB:=10}"  # fallback if the JSON read fails for any reason
        log "Pre-flight: ensuring ≥${MIN_FREE_GB}GB free on $DEPLOY_HOST"
        # POSIX df: column 4 is Available KB. Convert to GB.
        FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
        : "${FREE_KB:=0}"
        FREE_GB=$(( FREE_KB / 1024 / 1024 ))
        log "  free: ${FREE_GB}GB / threshold: ${MIN_FREE_GB}GB"
        if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
            log "  insufficient — running cleanup (docker prune + log truncate + journal vacuum)"
            # Prune list, in order of safety (most-conservative → most-aggressive):
            #   1. truncate runaway container json-log files (>50M)
            #   2. /containers/prune          — stopped containers only
            #   3. /images/prune dangling     — only <none> tagged images
            #   4. /build/prune?all=true      — buildkit cache (rare on non-builder VMs)
            #   5. /images/prune until=720h   — UNUSED tagged images older than 30d.
            #      Surfaced 2026-05-05 (oci-mail incident): /var/lib/containerd
            #      held 12 GB of old tagged-but-unreferenced images that the prior
            #      4 steps couldn't touch. `until=720h` filter only removes images
            #      with no running/stopped container referencing them AND last
            #      used > 30 days ago — safe for steady-state VMs, cleans the
            #      historical pulls that accumulate over months.
            #   6. journalctl --vacuum-size=50M
            #   7. rm /var/disk-reserve/ballast.bin (engineered safety net)
            #
            # REVERTED 2026-05-05: an "orphan /var/lib/containerd" cleanup step
            # was added between (5) and (6) on the assumption that the absence
            # of a `containerd.service` systemd unit meant the directory was
            # leftover from a removed install. That assumption is FALSE on
            # modern docker installs: dockerd ships an embedded containerd
            # binary that does NOT register a separate systemd unit but still
            # uses /var/lib/containerd as its content store. The cleanup
            # destroyed docker's image cache and forced a re-pull on every
            # ship — directly counterproductive on the disk-pressure VMs the
            # cleanup was meant to help. Real fix for runaway containerd
            # content store: docker's own /images/prune (steps 3+5 above) GCs
            # via the containerd content reference graph; if that's not
            # reclaiming, the issue is upstream (manifest staleness) and
            # outside engine scope.
            # Additional safe prunes (added 2026-05-05 from oci-mail incident
            # post-mortem: 38 GB used, 4 GB free, blocked HM activation):
            #   - vm-system.tar.gz from /var/backups/evidence/* — these are
            #     legacy heavy snapshots from the pre-2026-04-20 evidence-
            #     collector script. The .nix source has been refactored to
            #     a lightweight version that doesn't write vm-system.tar.gz,
            #     but VMs whose HM ship has been failing still run the OLD
            #     deployed script (oci-mail had 4×793 MB = 3.2 GB of these
            #     orphan files). Safe to remove: lightweight script never
            #     regenerates them; heavy script's existing 7-day retention
            #     handles the next cycle if ship continues to fail.
            #   - apt cache (apt-get clean) — regenerable, cheap to clear.
            ssh_vm "sudo find /var/lib/docker/containers -name '*-json.log' -size +50M -exec truncate -s 0 {} + 2>/dev/null || true; \
                    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST http://localhost/containers/prune >/dev/null 2>&1 || true; \
                    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST 'http://localhost/images/prune?filters=%7B%22dangling%22%3A%7B%22true%22%3Atrue%7D%7D' >/dev/null 2>&1 || true; \
                    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST 'http://localhost/build/prune?all=true' >/dev/null 2>&1 || true; \
                    curl -sf --max-time 60 --unix-socket /var/run/docker.sock -X POST 'http://localhost/images/prune?filters=%7B%22until%22%3A%5B%22720h%22%5D%7D' >/dev/null 2>&1 || true; \
                    sudo find /var/backups/evidence -name 'vm-system.tar.gz' -delete 2>/dev/null || true; \
                    sudo apt-get clean -qq 2>/dev/null || true; \
                    sudo journalctl --vacuum-size=50M >/dev/null 2>&1 || true; \
                    sudo rm -f /var/disk-reserve/ballast.bin 2>/dev/null || true" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
            FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
            : "${FREE_KB:=0}"
            FREE_GB=$(( FREE_KB / 1024 / 1024 ))
            log "  after cleanup pass 1: ${FREE_GB}GB free"

            # Pass 2 (aggressive): if still under threshold, prune ALL unused
            # images regardless of age. "Unused" = no container references it
            # (running OR stopped). Running containers' images stay; everything
            # else — old HM image versions, prior pulls — is fair game.
            # Triggered ONLY when pass 1 left us short, so steady-state VMs
            # are unaffected.
            #
            # KEY DETAIL: Docker's /images/prune defaults to dangling-only.
            # To prune ALL unused (including tagged), pass dangling=false:
            #   filters={"dangling":["false"]}
            #     URL-encoded: %7B%22dangling%22%3A%5B%22false%22%5D%7D
            # This DOES catch the prior failed-ship HM image (tagged
            # ghcr.io/diegonmarcos/nixhm-sudo-<vm>:latest) when no exited
            # activation container still references it.
            if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
                log "  pass 2 (aggressive): pruning ALL unused images (incl. tagged) + gcroots + caches"
                ssh_vm "curl -sf --max-time 60 --unix-socket /var/run/docker.sock -X POST 'http://localhost/containers/prune?filters=%7B%22until%22%3A%5B%221m%22%5D%7D' >/dev/null 2>&1 || true; \
                        curl -sf --max-time 180 --unix-socket /var/run/docker.sock -X POST 'http://localhost/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D' >/dev/null 2>&1 || true; \
                        sudo find /nix/var/nix/gcroots/auto -maxdepth 1 -type l -mtime +7 -delete 2>/dev/null || true; \
                        sudo find /var/cache -mindepth 2 -type f -atime +14 -delete 2>/dev/null || true; \
                        sudo find /var/backups/evidence -maxdepth 1 -mindepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
                FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
                : "${FREE_KB:=0}"
                FREE_GB=$(( FREE_KB / 1024 / 1024 ))
                log "  after cleanup pass 2: ${FREE_GB}GB free"
            fi

            # Pass 3 (last resort): nix-store --gc on orphan store paths.
            # When prior failed ships' activation containers crashed mid-cp,
            # they left ~5GB of /nix/store paths with no HM generation root —
            # docker prune can't see them, only nix can. Resolve nix-store
            # binary at runtime (HM-managed VMs vary).
            #
            # IMPORTANT: pipe through `bash -s` — VMs default to fish/zsh
            # which can't parse `VAR=$(...)` bash syntax. Same pattern as
            # the docker-real preflight nuke above.
            if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
                log "  pass 3 (nix GC): collecting orphan /nix/store paths"
                NIX_GC_SCRIPT='#!/bin/bash
# Prefer profile-wrapper bins (env baked in via patchelf rpath), fallback to
# raw store binary with LD_LIBRARY_PATH from the same -nix-2.x package lib.
# Direct invocation of /nix/store/*-nix-2.*/bin/nix-store fails with
# `libseccomp.so.2: cannot open shared object file` because sudo strips
# the env that would normally let the dynamic linker find it.
NIX_STORE_BIN=""
for _candidate in /nix/var/nix/profiles/default/bin/nix-store /home/'"$HM_USER"'/.nix-profile/bin/nix-store /nix/var/nix/profiles/per-user/'"$HM_USER"'/profile/bin/nix-store /nix/var/nix/profiles/per-user/root/profile/bin/nix-store; do
  if [ -x "$_candidate" ]; then NIX_STORE_BIN="$_candidate"; break; fi
done
if [ -z "$NIX_STORE_BIN" ]; then
  # Fallback: raw store binary + LD_LIBRARY_PATH derived from same package
  NIX_STORE_BIN=$(ls -1d /nix/store/*-nix-2.*/bin/nix-store 2>/dev/null | grep -v -- "-man" | sort -V | tail -1)
  if [ -x "$NIX_STORE_BIN" ]; then
    NIX_LIB_DIR="$(dirname "$(dirname "$NIX_STORE_BIN")")/lib"
    # Discover libseccomp from /nix/store
    LIBSECCOMP_DIR=$(ls -1d /nix/store/*-libseccomp-*/lib 2>/dev/null | sort -V | tail -1)
    export LD_LIBRARY_PATH="$NIX_LIB_DIR:$LIBSECCOMP_DIR:${LD_LIBRARY_PATH:-}"
    echo "[hm-preflight] LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
  fi
fi
if [ -x "$NIX_STORE_BIN" ]; then
  echo "[hm-preflight] running $NIX_STORE_BIN --gc"
  sudo LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$NIX_STORE_BIN" --gc 2>&1 | tail -5
else
  echo "[hm-preflight] no nix-store binary found"
fi'
                printf '%s' "$NIX_GC_SCRIPT" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
                FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
                : "${FREE_KB:=0}"
                FREE_GB=$(( FREE_KB / 1024 / 1024 ))
                log "  after cleanup pass 3: ${FREE_GB}GB free"
            fi

            if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
                log "ERROR: $DEPLOY_HOST still under disk threshold (${FREE_GB}GB < ${MIN_FREE_GB}GB)"
                log "       activation would fail with ENOSPC at nix-build mkdir."
                log "       Free disk manually or increase VM disk size, then retry."
                return 1
            fi
        fi

        # ── Pre-flight: NUKE every docker-real wrapper anywhere on the VM ──
        # The retired guardrails.nix used to install a `pkgs.writeShellScriptBin
        # "docker"` overlay that exec'd `nice /usr/local/bin/docker-real "$@"`.
        # `docker-real` was a system-side wrapper that has since been removed
        # (commit a0774f4ce). On VMs whose nix-profile still points to that
        # stale 2-line wrapper (or whose /nix/store/.../docker file got
        # overwritten in place — yes that happened on gcp-proxy), the engine's
        # `docker pull` step dies with
        #   nice: '/usr/local/bin/docker-real': No such file or directory
        # BEFORE the activation container runs, so scheduler.nix's cleanup
        # hook is unreachable. Run the nuke here, every ship, idempotent on
        # healthy VMs (the grep filter returns nothing → nothing removed).
        # Targets:
        #   1. PATH-visible wrappers (~/.nix-profile/bin/docker, /usr/local/bin/docker*)
        #   2. The mutated /nix/store/*-docker-*/bin/docker file the wrapper
        #      points to — purge it so HM activation re-instantiates a clean
        #      docker derivation. (chmod +w needed: /nix/store is RO by default.)
        #   3. Any /usr/local/bin/docker-real* leftovers (broken targets).
        log "Pre-flight: nuking docker-real wrappers on $DEPLOY_HOST"
        # IMPORTANT: pipe through `bash -s` — VMs may default to fish/zsh which
        # cannot parse this bash script. Mirror the activation step's pattern.
        PREFLIGHT_NUKE=$(cat <<PREFLIGHT_EOF
#!/bin/bash
set +e
HM_USER="$HM_USER"
# 1. Remove every PATH-visible wrapper that exec's docker-real
for _p in /home/\$HM_USER/.nix-profile/bin/docker /usr/local/bin/docker /usr/local/bin/docker-real /usr/local/bin/docker-capped /usr/local/bin/docker-compose-capped /usr/local/bin/docker-buildx-capped; do
  if [ -e "\$_p" ] && head -2 "\$_p" 2>/dev/null | grep -q 'docker-real'; then
    sudo rm -f "\$_p" && echo "[hm-preflight] purged wrapper: \$_p"
  fi
done
# 2. Hunt mutated docker-real bytes inside /nix/store and rm so HM rebuilds clean.
#    nix-store paths are content-addressed; if contents drift the path is corrupt.
for _p in /nix/store/*-docker-*/bin/docker; do
  [ -e "\$_p" ] || continue
  if head -2 "\$_p" 2>/dev/null | grep -q 'docker-real'; then
    sudo chmod -R +w "\$(dirname "\$_p")" 2>/dev/null
    sudo rm -f "\$_p" && echo "[hm-preflight] purged corrupted nix-store wrapper: \$_p"
  fi
done
# 3. Remove broken docker-real targets entirely
sudo rm -f /usr/local/bin/docker-real* 2>/dev/null
exit 0
PREFLIGHT_EOF
)
        printf '%s' "$PREFLIGHT_NUKE" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE" || true

        # Deploy pre-decrypted secrets to VM via SSH
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Deploying secrets to $DEPLOY_HOST"
            ssh_vm "mkdir -p ~/.config/home-manager/.secrets.d"
            scp $SSH_OPTS "$DIST_DIR/.secrets" "$DEPLOY_HOST:~/.config/home-manager/.secrets"
            if [ -d "$DIST_DIR/.secrets.d" ]; then
                scp $SSH_OPTS -r "$DIST_DIR/.secrets.d/"* "$DEPLOY_HOST:~/.config/home-manager/.secrets.d/" 2>/dev/null || true
            fi
            ssh_vm "chmod 600 ~/.config/home-manager/.secrets ~/.config/home-manager/.secrets.d/* 2>/dev/null || true"
            log "Secrets deployed"
        fi

        # Build the remote script with variables substituted
        REMOTE_SCRIPT=$(_build_docker_activate_script)
        REMOTE_SCRIPT=$(printf '%s' "$REMOTE_SCRIPT" | sed "s|@@IMAGE@@|$HM_IMAGE|g; s|@@TAG@@|latest|g; s|@@HM_USER@@|$HM_USER|g")

        # ── Activate over SSH, with retry on transient tunnel drops ──
        # The activation streams a multi-minute remote script (pull image →
        # activation container cp -aR ~5-7GB closure → register → activate)
        # over a single SSH session. On the CPU-constrained E2-Micro hubs the
        # heavy cp starves WireGuard keepalive handling → the wg hub kicks the
        # 10.0.0.200 cloud-builder peer → SSH drops with exit 255 mid-copy and
        # the whole ship fails (oci-analytics wg-public-peer add, 2026-06-24).
        # exit 255 is SSH's own "connection lost" code — distinct from any code
        # the remote bash returns. The activation is fully idempotent (pull,
        # container cp, --load-db, chown, activate all re-runnable; a dropped
        # run rolls the generation back cleanly), so re-establishing the tunnel
        # and re-running is safe. Retry ONLY on 255 (transient transport); a
        # non-255 exit is a real remote-script error → fail fast, don't mask it.
        # Knobs reuse the same build.retry.* config as run_with_retry (buildx).
        _hm_attempts="$(get_config build.retry.attempts)"; [ -z "$_hm_attempts" ] && _hm_attempts=3
        _hm_backoff="$(get_config build.retry.backoff_secs)"; [ -z "$_hm_backoff" ] && _hm_backoff=30
        _hm_try=0
        COMPOSE_RC=1
        while [ "$_hm_try" -lt "$_hm_attempts" ]; do
            _hm_try=$(( _hm_try + 1 ))
            log "Docker HM activate on $DEPLOY_HOST (attempt $_hm_try/$_hm_attempts)"
            set +e
            printf '%s' "$REMOTE_SCRIPT" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE"
            COMPOSE_RC=${PIPESTATUS[1]}
            set -e
            [ "$COMPOSE_RC" -eq 0 ] && break
            # Non-255 = remote script error (ENOSPC, daemon down, activate fail)
            # → persistent, don't retry. 255 = transport drop → retry.
            if [ "$COMPOSE_RC" -ne 255 ]; then
                break
            fi
            if [ "$_hm_try" -lt "$_hm_attempts" ]; then
                log "SSH dropped (exit 255) mid-activation — tunnel reset; retrying in ${_hm_backoff}s..."
                sleep "$_hm_backoff"
            fi
        done
        if [ "$COMPOSE_RC" -ne 0 ]; then
            log "FAILED (exit $COMPOSE_RC): Docker HM activate on $DEPLOY_HOST (after $_hm_try attempt(s))"
            return 1
        fi
        log "Docker HM activated on $DEPLOY_HOST"

    elif [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: full nix run on VM ──
        log "Activating on $DEPLOY_HOST (remote build)"
        SWITCH_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --option eval-cache false --flake .#$HM_CONFIG -b backup"
        log "Remote cmd: $SWITCH_CMD"
        set +e
        ssh_vm "bash -c '$SWITCH_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
        SWITCH_RC=${PIPESTATUS[0]}
        set -e
        if [ "$SWITCH_RC" -ne 0 ]; then
            log "FAILED (exit $SWITCH_RC): HM switch on $DEPLOY_HOST"
            return 1
        fi
    else
        # ── Local build: activate pre-built closure (no nix eval on VM) ──
        CLOSURE=$(cat "$SERVICE_DIR/.closure-path" 2>/dev/null || true)
        if [ -z "$CLOSURE" ]; then
            log "ERROR: no .closure-path — run deploy first"
            return 1
        fi
        log "Activating pre-built closure on $DEPLOY_HOST"
        ACTIVATE_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; $CLOSURE/activate"
        log "Remote cmd: $ACTIVATE_CMD"
        set +e
        ssh_vm "bash -c '$ACTIVATE_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
        ACTIVATE_RC=${PIPESTATUS[0]}
        set -e
        if [ "$ACTIVATE_RC" -ne 0 ]; then
            log "FAILED (exit $ACTIVATE_RC): HM activate on $DEPLOY_HOST"
            return 1
        fi
        rm -f "$SERVICE_DIR/.closure-path"
    fi

    log "Activated $HM_CONFIG on $DEPLOY_HOST"

    # ── Post-activation: profile health + cleanup ──
    set +e
    # Ensure nix default profile is healthy
    ssh_vm 'bash -c '\''
        PROFILE_DIR=/nix/var/nix/profiles/per-user/root
        DEFAULT=/nix/var/nix/profiles/default
        if [ -L "$DEFAULT" ] && [ -d "$PROFILE_DIR" ]; then
            CURRENT=$(readlink -f "$DEFAULT")
            if [ ! -x "$CURRENT/bin/nix-collect-garbage" ] 2>/dev/null; then
                echo "[hm] nix profile broken — nix-collect-garbage missing"
                for link in "$PROFILE_DIR"/profile-*-link; do
                    TARGET=$(readlink -f "$link" 2>/dev/null)
                    if [ -x "$TARGET/bin/nix-collect-garbage" ]; then
                        GOOD=$(basename "$link")
                        echo "[hm] Restoring default profile → $GOOD"
                        sudo ln -sfn "$GOOD" "$PROFILE_DIR/profile"
                        break
                    fi
                done
            fi
        fi
    '\''' 2>&1 | tee -a "$BUILD_LOG_FILE" || true

    # Trim to last 3 generations (bash -c for fish-shell VMs)
    ssh_vm 'bash -c "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; nix-env --delete-generations +3 2>/dev/null || true"' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    # Only GC if >2GB free RAM
    ssh_vm 'bash -c "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; MEM=\$(awk \"/MemAvailable/ {print int(\\\$2/1024)}\" /proc/meminfo); [ \"\$MEM\" -gt 2048 ] && nix-collect-garbage 2>/dev/null || echo \"[hm] Skipping GC (\${MEM}MB free < 2GB threshold)\""' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    set -e
    log "Generations trimmed on $DEPLOY_HOST"
}
