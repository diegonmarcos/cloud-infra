# Step: status — reconcile report (desired GHCR digest vs running digest + health)
# Sourced by cloud-ship-container-engine.sh — do not execute directly.
#
# The Kubernetes `rollout status` analogue. Read-only: no build, no deploy, no
# mutation of any kind. Answers three questions per container:
#   1) InSync?  running image digest == pushed GHCR digest (for the VM's arch)
#   2) Health?  container State + Health.Status
#   3) Config?  VM's stored .dist-hash == local dist/ hash
#
# Digest compare — the one sharp edge (see PLAN-engine-verbs.md §5):
# `$FULL_IMAGE:latest` is a multi-arch INDEX. Depending on how the VM pulled,
# a container's RepoDigest may record the index digest OR the per-arch manifest
# digest. So we build a candidate SET {index digest} ∪ {all per-arch manifest
# digests} and call InSync if the running RepoDigest is in it. This avoids the
# false-Drift that a naive "index-only" compare would produce on a correct
# arm64 deploy.

step_status() {
    CURRENT_STEP="status"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — status is VM-only, nothing to report"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Registry we own — only images under it get a digest reconcile check;
    # upstream images (postgres, redis, …) show n/a.
    OUR_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}"

    # ── Config plane: local dist hash vs VM stored hash ───────────────
    LOCAL_HASH="$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)"
    VM_HASH="$(ssh_with_retry "$DEPLOY_HOST" "cat '$DEPLOY_PATH/.dist-hash' 2>/dev/null" 2>/dev/null || true)"
    if [ -n "$LOCAL_HASH" ] && [ "$LOCAL_HASH" = "$VM_HASH" ]; then
        CFG="in-sync"
    elif [ -z "$VM_HASH" ]; then
        CFG="unknown"
    else
        CFG="DRIFT"
    fi

    # ── Observed state (VM side), one SSH round-trip per container ─────
    log "═══ status: $SERVICE_NAME @ $DEPLOY_HOST  (config: $CFG) ═══"
    printf "  %-24s %-10s %-12s %-8s\n" "CONTAINER" "STATE" "HEALTH" "IMAGE"

    _cnames="$(jq -r '.containers[]?.container_name // empty' "$SERVICE_DIR/build.json" 2>/dev/null)"
    [ -z "$_cnames" ] && { log_warn "No containers[].container_name in build.json"; return 0; }

    OVERALL=0
    [ "$CFG" = "DRIFT" ] && OVERALL=1
    # for-loop over shell-safe container names (no pipe): avoids the subshell
    # (so OVERALL propagates) AND the classic "ssh eats the while-loop's stdin"
    # bug that made only the first container iterate.
    for c in $_cnames; do
        [ -z "$c" ] && continue
        # Fetch raw `docker inspect` JSON and parse it LOCALLY with jq. Go
        # `--format` templates with {{if}}/{{index}} do not survive the
        # sh→ssh→fish→bash quoting layers (oci-apps login shell is fish); a
        # plain `docker inspect <name>` has no braces so fish passes it clean.
        _json="$(ssh_with_retry "$DEPLOY_HOST" "docker inspect $c 2>/dev/null" || true)"
        if [ -z "$_json" ] || ! printf '%s' "$_json" | jq -e 'length>0' >/dev/null 2>&1; then
            printf "  %-24s %-10s %-12s %-8s\n" "$c" "ABSENT" "-" "-"
            OVERALL=1
            continue
        fi
        _state="$(printf '%s' "$_json" | jq -r '.[0].State.Status // "-"')"
        _health="$(printf '%s' "$_json" | jq -r '.[0].State.Health.Status // "-"')"
        _cimg="$(printf '%s' "$_json" | jq -r '.[0].Config.Image // ""')"
        _repodig="$(printf '%s' "$_json" | jq -r '.[0].RepoDigests[0] // ""')"

        # Digest verdict only for containers running an image WE push to GHCR.
        # Desired = digests of the exact image ref this container runs (handles
        # the -binaries variant etc. without hardcoding); observed = its
        # RepoDigest. `:latest` is a multi-arch index, so accept either the
        # index digest or any per-arch manifest digest (PLAN §5 sharp edge).
        _sync="n/a"
        case "$_cimg" in
            "$OUR_REGISTRY"/*)
                _dig="${_repodig##*@}"   # repo@sha256:… → sha256:…
                _desired="$( { docker manifest inspect "$_cimg" 2>/dev/null | jq -r '.manifests[]?.digest // empty, .config.digest // empty'; \
                               docker buildx imagetools inspect "$_cimg" --format '{{.Manifest.Digest}}' 2>/dev/null; } \
                             | grep '^sha256:' | sort -u )"
                if [ -z "$_desired" ]; then
                    _sync="UNKNOWN"
                elif [ -n "$_dig" ] && printf '%s\n' "$_desired" | grep -qxF "$_dig"; then
                    _sync="in-sync"
                else
                    _sync="DRIFT"; OVERALL=1
                fi
                ;;
        esac

        printf "  %-24s %-10s %-12s %s\n" "$c" "$_state" "$_health" "$_sync"
        # Not-running or unhealthy → drift.
        case "$_state" in running) ;; *) OVERALL=1 ;; esac
        [ "$_health" = "unhealthy" ] && OVERALL=1
    done

    if [ "$OVERALL" -eq 0 ]; then
        log "RECONCILED — all containers in-sync, healthy, config matches"
    else
        log_warn "DRIFT — run 'build.sh ship' (config/image) or 'build.sh rollout' (image only) to reconcile"
    fi
    return "$OVERALL"
}
