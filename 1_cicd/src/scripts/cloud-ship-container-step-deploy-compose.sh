# Step: Run containers on VM via docker compose (standard or custom)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_compose() {
    CURRENT_STEP="compose"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Ensure Docker daemon is running
    if ! ssh_with_retry "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
        log_warn "Docker not running on $DEPLOY_HOST — starting"
        ssh_with_retry "$DEPLOY_HOST" "sudo systemctl start docker" 2>/dev/null || true
        sleep 5
        if ! ssh_with_retry "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
            log_error "Docker failed to start on $DEPLOY_HOST"
            return 1
        fi
    fi

    # Repair: /root/.docker/config.json may exist as a DIRECTORY due to a
    # historical `docker run -v /root/.docker/config.json:...` bind-mount
    # where the host path was missing — docker auto-creates such paths as
    # directories. Subsequent `sudo docker compose pull` then fails with
    # auth/manifest errors because /root/.docker/config.json can't be read
    # as a JSON file. Idempotent: no-op when the path is a regular file or
    # missing. Same fix applied to RUNNER_HOST in step_docker (line ~458).
    # Re-login follows so private GHCR pulls work.
    GHCR_TOKEN_FILE="${HOME}/git/cloud-vault/A0_keys/providers/github/api-key_opaque/token"
    if [ -f "$GHCR_TOKEN_FILE" ]; then
        GHCR_TOKEN_VAL="$(cat "$GHCR_TOKEN_FILE")"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        # ponytail: GHA context — vault not mounted, fall back to Actions token
        GHCR_TOKEN_VAL="$GITHUB_TOKEN"
    fi
    if [ -n "${GHCR_TOKEN_VAL:-}" ]; then
        # Use bash -c explicitly: target VMs may use fish/zsh as login shell
        # (e.g. oci-apps's diego user runs fish), and fish does not support
        # bash if/then/fi syntax; this wrapper guarantees POSIX semantics.
        ssh_with_retry "$DEPLOY_HOST" 'bash -c '"'"'
            if sudo test -d /root/.docker/config.json; then
                echo "[deploy-compose] /root/.docker/config.json is a DIRECTORY — repairing"
                sudo rm -rf /root/.docker/config.json
            fi
            sudo mkdir -p /root/.docker
        '"'" 2>&1 | while IFS= read -r line; do log "$line"; done
        # Login as root so `sudo docker compose pull` can fetch private GHCR images.
        #
        # Detached, not ssh_with_retry: `docker login` does a network round-trip
        # to ghcr.io from the VM and takes ~60s on a loaded/distant host. Held
        # over one ssh session it dropped with 255 on all 3 attempts
        # (chat-mattermost → oci-apps, runs 30756461937 / 30757890274), the
        # failure was swallowed as "non-fatal", and every subsequent private
        # image pull then failed with the far less obvious `denied: denied`.
        #
        # The token goes over stdin into a umask-077 file rather than into the
        # uploaded payload — ssh_run_detached leaves that script on /tmp while
        # it runs, and a secret has no business sitting there.
        _ghcr_tok="/tmp/.ghcr-tok-$$"
        printf '%s\n' "$GHCR_TOKEN_VAL" \
            | ssh $SSH_OPTS "$DEPLOY_HOST" "umask 077; cat > $_ghcr_tok" || true
        if ssh_run_detached "$DEPLOY_HOST" \
               "sudo docker login ghcr.io -u diegonmarcos --password-stdin < $_ghcr_tok >/dev/null 2>&1; _rc=\$?; rm -f $_ghcr_tok; exit \$_rc" \
               "ghcr-login-$(basename "$DEPLOY_PATH")"; then
            log "GHCR login OK on $DEPLOY_HOST"
        else
            log_warn "GHCR login on $DEPLOY_HOST failed — pulls of PRIVATE ghcr.io images will fail with 'denied' below; public images still work"
            ssh $SSH_OPTS "$DEPLOY_HOST" "rm -f $_ghcr_tok" >/dev/null 2>&1 || true
        fi
    fi
    # Clear stale non-root docker credentials so public GHCR images pull
    # anonymously without an expired ubuntu-user token causing "denied".
    ssh_with_retry "$DEPLOY_HOST" "docker logout ghcr.io >/dev/null 2>&1 || true"

    # Pre-hook (runs on VM before containers start)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        if ssh_with_retry "$DEPLOY_HOST" "grep -q 'entrypoint.*$COMPOSE_PRE_HOOK' $DEPLOY_PATH/$REMOTE_COMPOSE_REL 2>/dev/null"; then
            log "Skipping pre_hook '$COMPOSE_PRE_HOOK' — container entrypoint"
        else
            log "Running pre-hook: $COMPOSE_PRE_HOOK"
            # Detached, not ssh_with_retry: hooks are minute-scale remote work
            # (fetch-mcp-bearer.sh does an OIDC round-trip), and holding one ssh
            # session open for them hits the same transport drop the compose
            # payload hits. chat-mattermost → oci-apps, 2026-08-02: every attempt
            # died at ~60s with exit 255, and each retry re-ran the whole hook
            # from scratch — 4 runs, ~6 min, then the ship failed. Detached keeps
            # the hook running across a dropped poll and returns its REAL rc.
            ssh_run_detached "$DEPLOY_HOST" \
                "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK" \
                "prehook-$(basename "$DEPLOY_PATH")"
        fi
    fi

    # ── Compose up policy: NEVER build on the deploy VM. ──
    # All images are pre-built by the engine and pushed to GHCR (step_docker).
    # VMs only PULL — they never rebuild. --no-build (ALWAYS set) keeps 1GB
    # e2-micro VMs alive (compose `build` would OOM) and guarantees the running
    # image matches what was tested in CI. `--build` in build.json's
    # deploy.compose_flags is IGNORED; the engine logs a warning below.
    #
    # ── Recreate / pull policy: decoupled ensure-running vs. real redeploy ──
    # step_compose now ALWAYS runs in the ship pipeline — even when nothing
    # changed — so a container stopped out-of-band (load-shedder killing docker,
    # VM reboot) is brought back `up` (gcp-proxy's whole stack sat Exited while
    # two `ship` re-dispatches no-op'd, 2026-06). See the Phase-3 comment in
    # cloud-ship-container-engine.sh. To keep that cheap, pull + recreate are
    # derived from what actually changed:
    #   • --pull always    → only when the image changed ($DOCKER_IMAGE_CHANGED).
    #     The fleet pins :latest tags, so "missing" once let a stale locally
    #     cached image shadow a freshly-pushed GHCR image forever — crawlee's
    #     amd64 mispush (run 27409752538) kept winning over the corrected arm64
    #     build. When the image is UNCHANGED there is nothing new to fetch, so we
    #     use --pull missing (no needless registry hit; local cache authoritative).
    #   • --force-recreate → only when image OR config changed. A pure
    #     ensure-running `up -d` restarts stopped containers WITHOUT recreating
    #     already-running ones, so re-running ship on an unchanged stack is a
    #     near-no-op that still heals a shed/stopped container.
    #
    # DOCKER_IMAGE_CHANGED / CONFIG_CHANGED are set by the ship pipeline. When
    # step_compose is invoked standalone (`build.sh compose`) both are UNSET; we
    # then keep the historical full refresh (pull always + force-recreate) so the
    # manual command still forces a clean redeploy.
    if [ -z "${DOCKER_IMAGE_CHANGED+x}" ] && [ -z "${CONFIG_CHANGED+x}" ]; then
        _PULL_POLICY="--pull always"; _RECREATE="--force-recreate"; COMPOSE_PULL_FIRST="true"
    else
        if [ -n "${DOCKER_IMAGE_CHANGED:-}" ]; then
            _PULL_POLICY="--pull always"; COMPOSE_PULL_FIRST="true"
        else
            _PULL_POLICY="--pull missing"; COMPOSE_PULL_FIRST="false"
        fi
        if [ -n "${DOCKER_IMAGE_CHANGED:-}" ] || [ -n "${CONFIG_CHANGED:-}" ]; then
            _RECREATE="--force-recreate"
        else
            _RECREATE=""
        fi
    fi
    COMPOSE_UP_FLAGS="--no-build $_PULL_POLICY $_RECREATE"
    if echo "$COMPOSE_FLAGS" | grep -q -- '--build'; then
        log_warn "deploy.compose_flags contains --build but VM rebuilds are disabled — using --no-build (engine pushes pre-built images to GHCR)"
    fi

    # v1→v2 layout migration cleanup. Older deploys placed docker-compose.yml at
    # the project ROOT; v2 canonical is a subdir (compose/docker-compose.yml). A
    # lingering root file lets `docker compose` (or any `cd $dir && docker
    # compose up`, e.g. the cloud-infra-local MCP tool) start a SECOND compose
    # project that grabs the same explicit `container_name`. The canonical
    # `down --remove-orphans` only evicts its own project, so that foreign
    # container then blocks `up` with "container name already in use" (cloud-mail-mcp,
    # 2026-06-16). When canonical compose lives in a subdir, tear down + delete
    # any stale root file first so deploys stay idempotent. Runs on the VM; no
    # single quotes (embedded into a single-quote-wrapped bash -c PAYLOAD).
    LEGACY_COMPOSE_CLEANUP=""
    case "$REMOTE_COMPOSE_REL" in
        */*) LEGACY_COMPOSE_CLEANUP='if [ -f docker-compose.yml ]; then docker compose -f docker-compose.yml --project-directory . down --remove-orphans 2>/dev/null || true; rm -f docker-compose.yml; fi' ;;
    esac

    # Foreign-project container eviction. Our `down --remove-orphans` runs with
    # project = basename($DEPLOY_PATH) (via --project-directory .), so it ONLY
    # removes containers compose recorded under THAT project. A container created
    # under a DIFFERENT project with the same explicit container_name — e.g. a
    # manual `cd compose && docker compose up` (project="compose") or the
    # cloud-infra MCP devops_docker_compose_up — survives the `down`, then blocks
    # `up` with "container name already in use" (wireguard-mesh + etherpad_postgres,
    # 2026-06-22). Force-remove the declared container_names by hand first:
    # idempotent (no-op when `down` already removed them), data-driven from
    # build.json, and lossless — `docker rm -f` drops only the container, named
    # volumes persist.
    EVICT_NAMED=""
    _cnames="$(jq -r '.containers[]?.container_name // empty' "$SERVICE_DIR/build.json" 2>/dev/null | tr '\n' ' ')"
    [ -n "$_cnames" ] && EVICT_NAMED="for c in $_cnames; do docker rm -f \"\$c\" 2>/dev/null || true; done"

    # EVICT_NAMED only knows the names we declare NOW, so it cannot see the one
    # container that matters after a rename: the predecessor, still running
    # under the OLD name, still holding the host port. `down` misses it too —
    # different project, different name — and `up` then dies with
    #   driver failed programming external connectivity on endpoint
    #   cloud-services-mcp: Bind for 10.0.0.6:3101 failed: port is already
    #   allocated
    # which is what happened to c3-services-mcp → cloud-services-mcp (and
    # mail-mcp, mattermost-mcp) on oci-apps. Renaming a service is supposed to
    # be an identity-only change, so it must not require hand-reaping the old
    # container on the box.
    #
    # A host ip:port in our compose file is OUR declaration of that binding —
    # the fleet gives each service a unique one. Anything else holding it is by
    # definition a stale predecessor, so evict on the binding, not on the name.
    # Scoped tightly: only exact host bindings this compose declares, and never
    # a container we ourselves named. `docker rm -f` drops the container only;
    # named volumes persist.
    # `|| true` is load-bearing, not defensive noise. A service with NO host
    # port bindings is normal (network_mode:host publishes nothing — maddy,
    # google-workspace-mcp, google-personal-mcp, ...), and then `grep` matches
    # nothing and exits 1. Under `set -o pipefail` that makes the whole
    # pipeline — and therefore this assignment — return 1, which `set -e`
    # turns into an immediate abort of the entire compose step.
    #
    # It only reproduces in CI: build.sh sets `-e` but not `pipefail`, while
    # GitHub Actions runs steps under `bash -eo pipefail` and exports
    # SHELLOPTS into child shells. So `build.sh compose` run by hand
    # succeeded while the identical code failed in every Ship run — which is
    # exactly how this hid since 1d43ef313. The symptom gave nothing away:
    # "Step 'compose' failed (exit 1)" logged ~9ms after the previous line,
    # no command having run, nothing reaching the VM.
    EVICT_PORTS=""
    _hostbinds="$(grep -oE '"[0-9][0-9.]*:[0-9]+:[0-9]+"' "$COMPOSE_FILE" 2>/dev/null \
        | tr -d '"' | sed 's/:[0-9]*$//' | sort -u | tr '\n' ' ' || true)"

    # ...and the blind spot in the above: it reads bindings off the RENDERED
    # compose, so a service on network_mode:host declares none and _hostbinds
    # comes back empty — even though the app still binds its port on the VM.
    # That is precisely the case this eviction exists for, and precisely the
    # case it missed. c3-services-mcp -> cloud-services-mcp switched to
    # network_mode:host in the same change as the rename, so the predecessor
    # kept 10.0.0.6:3101, the new container died on bind, and health saw an
    # empty `docker compose ps` for 46h. The fix already in the tree could not
    # have fired: there was nothing in the compose file to grep.
    #
    # So for host-network composes, take the port from build.json instead and
    # match it port-only (":3101->" against docker's HOSTIP:HOSTPORT->CPORT).
    # ONLY .ports.app, deliberately: the other keys are container-internal
    # (chat-mattermost declares db:5432, api:8080) and a port-only match on
    # those would reap an unrelated service that legitimately publishes them.
    # .ports.app is the one the fleet allocates uniquely per service, so
    # anything else holding it is by definition a stale predecessor.
    if grep -q '"network_mode":"host"' "$COMPOSE_FILE" 2>/dev/null; then
        _appport="$(jq -r '.ports.app // empty' "$SERVICE_DIR/build.json" 2>/dev/null)"
        case "$_appport" in
            ''|*[!0-9]*) ;;
            *) _hostbinds="$(printf '%s :%s' "$_hostbinds" "$_appport" | tr ' ' '\n' \
                   | grep -v '^$' | sort -u | tr '\n' ' ')" ;;
        esac
    fi
    [ -n "$_hostbinds" ] && EVICT_PORTS="for hp in $_hostbinds; do for c in \$(docker ps --format '{{.Names}} {{.Ports}}' | grep -F \"\$hp->\" | cut -d' ' -f1); do case \" $_cnames \" in *\" \$c \"*) ;; *) echo \"[compose] evicting \$c — it holds \$hp, which this service declares\"; docker rm -f \"\$c\" >/dev/null 2>&1 || true ;; esac; done; done"

    # EVICT_PORTS reads `docker ps --format '{{.Ports}}'`, which is EMPTY for a
    # container on network_mode:host — it publishes nothing. So it catches a
    # BRIDGED predecessor (c3-services-mcp published 10.0.0.6:3101->3101, and
    # that is the one it was written for) but is blind to a host-networked one.
    # c3-infra-mcp -> cloud-infra-mcp is exactly that second shape: both sides
    # host-networked, the old container holding 10.0.0.6:3100 while showing no
    # ports at all. Same 46h outage, invisible to every docker-level check.
    #
    # When docker cannot say who holds the port, ask the kernel: ss gives the
    # listening pid, /proc/<pid>/cgroup names the owning container. That works
    # regardless of the predecessor's network mode.
    #
    # sudo is required (the listener belongs to root inside the container) and
    # is already assumed by the rsync step's `sudo mkdir -p $DEPLOY_PATH`.
    EVICT_SOCKET=""
    if grep -q '"network_mode":"host"' "$COMPOSE_FILE" 2>/dev/null; then
        _appport="$(jq -r '.ports.app // empty' "$SERVICE_DIR/build.json" 2>/dev/null)"
        case "$_appport" in
            ''|*[!0-9]*) ;;
            *) EVICT_SOCKET="for p in \$(sudo ss -lntpH \"sport = :$_appport\" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do cid=\$(sudo sed -nE 's#.*[-/]([0-9a-f]{64})(\\.scope)?\$#\\1#p' /proc/\$p/cgroup 2>/dev/null | head -1); [ -n \"\$cid\" ] || continue; cn=\$(docker inspect --format '{{.Name}}' \"\$cid\" 2>/dev/null | sed 's#^/##'); [ -n \"\$cn\" ] || continue; case \" $_cnames \" in *\" \$cn \"*) ;; *) echo \"[compose] evicting \$cn — it holds :$_appport, which this service binds\"; docker rm -f \"\$cid\" >/dev/null 2>&1 || true ;; esac; done" ;;
        esac
    fi

    if [ "$COMPOSE_CUSTOM" = "true" ]; then
        # ── Custom compose script: self-contained, used by both ship + container-init ──
        # Generated in a tmpdir (ship transient — never pollutes dist/ or git working tree).
        SCRIPT_NAME="build-step-compose-custom.sh"
        TMP_SCRIPT="$(mktemp -t compose-custom.XXXXXX.sh)"
        trap 'rm -f "$TMP_SCRIPT"' EXIT
        log "Generating $SCRIPT_NAME (flags: $COMPOSE_UP_FLAGS)"
        {
            cat <<'COMPOSE_HEADER'
#!/bin/sh
set -e
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  docker info >/dev/null 2>&1 || { echo "[compose-custom] ERROR: Docker failed to start" >&2; exit 1; }
fi
# v2 layout: secrets live at compose/.secrets (alongside docker-compose.yml).
# But --project-directory . forces docker-compose's env_file resolution to
# ./.secrets at project root. Symlink so env_file: [".secrets"] in the YAML
# AND --env-file CLI both resolve to the same file.
ENV_FILE_FLAG=""
if [ -f compose/.secrets ]; then
  [ -e .secrets ] || ln -sf compose/.secrets .secrets
  ENV_FILE_FLAG="--env-file .secrets"
elif [ -f .secrets ]; then
  ENV_FILE_FLAG="--env-file .secrets"
fi
COMPOSE_HEADER
            # v2: compose at compose/ subdir; force project-dir=CWD for env_file/volumes resolution
            echo "COMPOSE_FILE_FLAG='-f $REMOTE_COMPOSE_REL --project-directory .'"
            [ -n "$LEGACY_COMPOSE_CLEANUP" ] && echo "$LEGACY_COMPOSE_CLEANUP"
            # Pull-gate: when refreshing to a new image, OBTAIN it BEFORE tearing
            # down the running container. A pull that fails (private/denied GHCR,
            # registry down) must NOT proceed to `down` unless the image is
            # already cached locally — otherwise a healthy container is destroyed
            # for an image we can't start (dagu outage 2026-07-11: private
            # dagu-binaries → pull denied → down → up couldn't pull → no
            # container). Since the gate pulls explicitly, `up` uses --pull
            # missing (below) so the cache-fallback path doesn't re-trigger the
            # failing pull.
            if [ "$COMPOSE_PULL_FIRST" = "true" ]; then
                cat <<'PULL_GATE'
if ! docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG pull; then
  echo "[compose-custom] pull failed — verifying local image cache before teardown" >&2
  _miss=0
  for _img in $(docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG config --images 2>/dev/null); do
    docker image inspect "$_img" >/dev/null 2>&1 || { echo "[compose-custom] ERROR: $_img neither pullable nor cached locally" >&2; _miss=1; }
  done
  [ "$_miss" = 0 ] || { echo "[compose-custom] ERROR: refusing to tear down running container(s) for an unobtainable image" >&2; exit 1; }
  echo "[compose-custom] images present locally — proceeding with cache" >&2
fi
PULL_GATE
            fi
            echo 'docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG down --remove-orphans 2>/dev/null || true'
            [ -n "$EVICT_NAMED" ] && echo "$EVICT_NAMED"
            [ -n "$EVICT_PORTS" ] && echo "$EVICT_PORTS"
            [ -n "$EVICT_SOCKET" ] && echo "$EVICT_SOCKET"
            # Gate already pulled → up must not re-pull (would re-hit the failure
            # on the cache-fallback path). Swap always→missing for the up line.
            _CUSTOM_UP_FLAGS="$COMPOSE_UP_FLAGS"
            [ "$COMPOSE_PULL_FIRST" = "true" ] && _CUSTOM_UP_FLAGS="${COMPOSE_UP_FLAGS/--pull always/--pull missing}"
            echo "docker compose \$COMPOSE_FILE_FLAG \$ENV_FILE_FLAG up -d $_CUSTOM_UP_FLAGS"
        } > "$TMP_SCRIPT"
        chmod +x "$TMP_SCRIPT"

        log "Deploying + running $SCRIPT_NAME on $DEPLOY_HOST"
        rsync -az "$TMP_SCRIPT" "$DEPLOY_HOST:$DEPLOY_PATH/$SCRIPT_NAME"
        # Same reasoning as the standard path below — this custom script also
        # pulls images, so it must not hold a single ssh session open either.
        ssh_run_detached "$DEPLOY_HOST" \
            "cd $DEPLOY_PATH && sh $SCRIPT_NAME; _rc=\$?; rm -f $SCRIPT_NAME; exit \$_rc" \
            "compose-custom-$(basename "$DEPLOY_PATH")"
        rm -f "$TMP_SCRIPT"
        trap - EXIT
    else
        # ── Standard: direct docker compose up ──
        # v2 layout: prefer compose/.secrets; fall back to ./.secrets. The flag
        # is resolved by the REMOTE shell, so the whole command MUST run under
        # bash — target VMs use fish as the login shell (e.g. oci-apps), and
        # fish rejects POSIX `$(...)` command substitution ("command
        # substitutions not allowed here"), silently dropping --env-file.
        # Without --env-file docker compose has NO interpolation source, so any
        # `${SECRET}` referenced inside an `environment:` value (e.g. a
        # DATABASE_URL embedding ${POSTGRES_PASSWORD}) renders EMPTY while
        # `env_file:` values still resolve via --project-directory — a silent,
        # asymmetric secret corruption (paca-api SASL auth failure, 2026-06-14).
        # Wrap in `bash -c` for guaranteed POSIX semantics — same pattern as the
        # GHCR-repair block above. PAYLOAD is built with double quotes only (no
        # single quotes) so it can be single-quote-wrapped for fish→bash verbatim.
        CF="-f $REMOTE_COMPOSE_REL --project-directory ."
        ENV_FILE_PROBE='ENV_FILE_FLAG="$([ -f compose/.secrets ] && echo --env-file compose/.secrets || { [ -f .secrets ] && echo --env-file .secrets; })"'
        log "Running docker compose up on $DEPLOY_HOST:$DEPLOY_PATH (compose=$REMOTE_COMPOSE_REL)"
        if [ "$COMPOSE_PULL_FIRST" = "true" ]; then
            # Pull-gate: obtain the new image BEFORE `down`. On pull failure,
            # proceed only if every image is already cached locally; otherwise
            # abort BEFORE teardown (never destroy a running container for an
            # image we can't start — dagu outage 2026-07-11). Gate pulls
            # explicitly → `up` uses --pull missing so the cache-fallback path
            # doesn't re-hit the failing pull.
            _STD_UP_FLAGS="${COMPOSE_UP_FLAGS/--pull always/--pull missing}"
            PULL_GATE="docker compose $CF \$ENV_FILE_FLAG pull || { for _img in \$(docker compose $CF \$ENV_FILE_FLAG config --images 2>/dev/null); do docker image inspect \"\$_img\" >/dev/null 2>&1 || { echo \"ERROR: \$_img neither pullable nor cached — refusing teardown\" >&2; exit 1; }; done; }"
            PAYLOAD="cd \"$DEPLOY_PATH\" && $ENV_FILE_PROBE; ${LEGACY_COMPOSE_CLEANUP:+$LEGACY_COMPOSE_CLEANUP; }$PULL_GATE; docker compose $CF \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; ${EVICT_NAMED:+$EVICT_NAMED; }${EVICT_PORTS:+$EVICT_PORTS; }${EVICT_SOCKET:+$EVICT_SOCKET; }docker compose $CF \$ENV_FILE_FLAG up -d $_STD_UP_FLAGS"
        else
            PAYLOAD="cd \"$DEPLOY_PATH\" && $ENV_FILE_PROBE; ${LEGACY_COMPOSE_CLEANUP:+$LEGACY_COMPOSE_CLEANUP; }docker compose $CF \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; ${EVICT_NAMED:+$EVICT_NAMED; }${EVICT_PORTS:+$EVICT_PORTS; }${EVICT_SOCKET:+$EVICT_SOCKET; }docker compose $CF \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        fi
        # Detached + poll, NOT one long-held ssh: the pull/extract can run for
        # minutes with an almost-idle ssh channel, which is exactly when the
        # wg path to the CI runner lapses and drops the stream (exit 255).
        # See ssh_run_detached in cloud-ship-container-engine.sh.
        ssh_run_detached "$DEPLOY_HOST" "$PAYLOAD" "compose-$(basename "$DEPLOY_PATH")"
    fi

    # Post-hook
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        log "Running post-hook: $COMPOSE_POST_HOOK"
        ssh_run_detached "$DEPLOY_HOST" \
            "cd $DEPLOY_PATH && chmod +x $COMPOSE_POST_HOOK && ./$COMPOSE_POST_HOOK" \
            "posthook-$(basename "$DEPLOY_PATH")"
    fi

    # Verify
    log "Verifying containers are running..."
    sleep 3
    ssh_with_retry "$DEPLOY_HOST" "docker ps --filter 'name=$(basename $DEPLOY_PATH)' --format '{{.Names}} {{.Status}}'" 2>/dev/null | while read -r line; do log "  $line"; done
    log "Done."
}
