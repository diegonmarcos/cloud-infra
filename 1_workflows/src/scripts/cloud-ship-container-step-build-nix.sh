# Step: Build nix flake (or copy-only for non-nix services)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_build() {
    CURRENT_STEP="build"

    # Simple copy mode: no nix, just copy src/ → dist/
    if [ "$BUILD_COPY_ONLY" = "true" ]; then
        log "Copying src/ -> dist/ (copy-only mode)"
        # Preserve terraform state if present
        if [ "$TERRAFORM_DEPLOY" = "true" ] && [ -d "$DIST_DIR" ]; then
            TF_BACKUP=$(mktemp -d)
            for f in terraform.tfstate terraform.tfstate.backup terraform.tfvars .terraform; do
                [ -e "$DIST_DIR/$f" ] && mv "$DIST_DIR/$f" "$TF_BACKUP/"
            done
            # Also preserve any .tfstate backups
            find "$DIST_DIR" -name '*.backup' -exec mv {} "$TF_BACKUP/" \; 2>/dev/null || true
        fi
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR"
        # Stamp every copied file with the GENERATED-FILE banner
        # (dist/ is engine output — must be distinguishable from src/).
        "$INJECT_HEADER" tree "$SRC_DIR" "$DIST_DIR"
        # Restore terraform state
        if [ -n "${TF_BACKUP:-}" ] && [ -d "$TF_BACKUP" ]; then
            cp -a "$TF_BACKUP/"* "$DIST_DIR/" 2>/dev/null || true
            rm -rf "$TF_BACKUP"
        fi
        chmod -R u+w "$DIST_DIR"
        log "Built files:"
        find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
        return 0
    fi

    # Pre-build: resolve any *.json symlink in src/ pointing OUTSIDE the service
    # dir. Nix flakes can't follow symlinks into submodules/parent dirs, so the
    # engine materialises them as real files before nix build and restores them
    # afterwards. Generic: no hardcoded filename patterns — src/ is the contract.
    CLOUD_DATA_STAGED=""
    CLOUD_DATA_DIR="$SERVICE_DIR/../../2_configs/dist"
    HAS_EXTERNAL_SYMLINKS=false

    # Detect any *.json symlink in src/ whose target is outside the service dir
    for f in "$SRC_DIR"/*.json; do
        [ -L "$f" ] || continue
        target=$(readlink -f "$f" 2>/dev/null || true)
        case "$target" in
            "$SERVICE_DIR"/*) ;;  # within service (e.g. build.json -> ../build.json) — nix can follow
            *)
                HAS_EXTERNAL_SYMLINKS=true
                break
                ;;
        esac
    done

    # Update cloud-data submodule to latest if anything depends on it.
    # In CI, dispatch already did this ONCE under flock — per-service updates
    # race on the submodule config lock, so we skip when CI pre-staged.
    if [ -n "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        log "cloud-data submodule already updated by CI dispatch — skipping"
    elif [ -f "$SERVICE_DIR/../../.gitmodules" ] && { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_EXTERNAL_SYMLINKS" = "true" ]; }; then
        log "Updating cloud-data submodule to latest (--remote --force)"
        # flock: parallel ships of different services on this host fight over
        # git submodule's per-config lock and corrupt each other. Serialize the
        # actual git invocation; once one runs --remote, the rest see the
        # already-current submodule and exit instantly. Lock-fd 9 + 60s timeout
        # guards CI runners with stuck previous flock holders.
        FLOCK_BIN="$(command -v flock || true)"
        if [ -n "$FLOCK_BIN" ]; then
            (
                "$FLOCK_BIN" -w 60 9 || { log "WARN: flock timed out — running unlocked"; }
                git -C "$SERVICE_DIR/../.." -c submodule."2_configs/dist".update=checkout \
                    submodule update --remote --init --force 2_configs/dist 2>&1 \
                    | while IFS= read -r line; do log "  $line"; done
            ) 9>/tmp/cloud-submodule-update.lock || \
                log "WARN: 2_configs/dist update failed — ship will use the pinned commit (may be stale)"
        else
            git -C "$SERVICE_DIR/../.." -c submodule."2_configs/dist".update=checkout \
                submodule update --remote --init --force 2_configs/dist 2>&1 \
                | while IFS= read -r line; do log "  $line"; done || \
                log "WARN: 2_configs/dist update failed — ship will use the pinned commit (may be stale)"
        fi
    fi

    # v2 engine flake reads 2_configs/dist/ directly; skip src/ injection
    IS_V2_ENGINE_PRE="false"
    if [ -f "$SRC_DIR/flake.nix" ] && grep -q '_shared/engine.nix' "$SRC_DIR/flake.nix"; then
        IS_V2_ENGINE_PRE="true"
    fi

    # HYBRID GUARD v2 (2026-07-03, final form): EVERY v2 flake carries external
    # per-service registry symlinks — the repo-wide git intern resolves them,
    # so dereferencing is not just unnecessary, it deterministically BREAKS v2
    # evals (every "(symlinks +flag)" build tonight failed; every short-circuit
    # passed). The ONLY case that needs dereferencing is a PATH-INTERPOLATED
    # symlink inside a runCommand (cloud-spec: DATA=''${./cloud-data.json}) —
    # nix interns that single path verbatim → dangling in the store. That case
    # is declared, not inferred: build.json build.dereference_symlinks=true.
    DEREF_SYMLINKS=$(jq -r '.build.dereference_symlinks // false' "$CONFIG" 2>/dev/null)
    if [ "$IS_V2_ENGINE_PRE" = "true" ] && [ "$DEREF_SYMLINKS" != "true" ]; then
        log "v2 engine flake — cloud-data accessed via 2_configs/dist, no src/ resolve needed"
    elif { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_EXTERNAL_SYMLINKS" = "true" ]; } && [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        # Resolve every external *.json symlink to a real file
        for f in "$SRC_DIR"/*.json; do
            [ -L "$f" ] || continue
            target=$(readlink -f "$f" 2>/dev/null || true)
            case "$target" in
                "$SERVICE_DIR"/*) continue ;;
            esac
            [ -f "$target" ] || continue
            rm "$f"
            cp "$target" "$f"
            git -C "$SERVICE_DIR/../.." add "$(realpath --relative-to="$SERVICE_DIR/../.." "$f")" 2>/dev/null || true
            CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $f"
        done
        # include_cloud_data=true: also copy every 2_configs/dist/*.json into src/ (for services
        # that need the whole dataset at runtime, e.g. c3-infra-mcp-api).
        # NEVER for v2 engine flakes (2026-07-03): they read 2_configs/dist
        # directly through the repo-wide git intern; dumping 60 alien JSONs
        # into src/ broke their eval (rig, cgc-mcp) when the hybrid guard
        # routed them here for symlink dereferencing.
        if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ -d "$CLOUD_DATA_DIR" ] && [ "$IS_V2_ENGINE_PRE" != "true" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                BASENAME=$(basename "$f")
                TARGET="$SRC_DIR/$BASENAME"
                [ -L "$TARGET" ] && continue  # already handled above
                cp "$f" "$TARGET"
                git -C "$SERVICE_DIR/../.." add "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" 2>/dev/null || true
                CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $TARGET"
            done
        fi
        log "Resolved cloud-data for nix build (${HAS_EXTERNAL_SYMLINKS:+symlinks}${INCLUDE_CLOUD_DATA:+ +flag})"
    elif { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_EXTERNAL_SYMLINKS" = "true" ]; }; then
        log "cloud-data already pre-staged by CI — skipping"
    fi

    # build.json: src/build.json is a symlink to ../build.json (root is source of truth)
    if [ -f "$SERVICE_DIR/build.json" ] && [ ! -L "$SRC_DIR/build.json" ]; then
        ln -sf ../build.json "$SRC_DIR/build.json"
        git -C "$SERVICE_DIR/../.." add "$(realpath --relative-to="$SERVICE_DIR/../.." "$SRC_DIR/build.json")" 2>/dev/null || true
        log "Created build.json symlink in src/"
    fi

    log "Building nix flake -> dist/"
    cd "$SRC_DIR"

    BUILD_LOG=$(mktemp)
    REPO_ROOT="$SERVICE_DIR/../.."

    # nix build — runs directly (in GHA this is already inside cloud-builder container)
    git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true
    nix build --option eval-cache false --out-link "$SERVICE_DIR/.result" 2>"$BUILD_LOG" || {
        log_error "nix build failed:"
        # BOTH streams (2026-07-03): the engine self-tees stdout into
        # <service>/build.log; an error cat'd only to stderr never reaches it
        # and failures debug blind ("Step 'build' failed" with no cause).
        cat "$BUILD_LOG"
        cat "$BUILD_LOG" >&2
        rm -f "$BUILD_LOG"
        for f in $CLOUD_DATA_STAGED; do
            REL_PATH="$(realpath --relative-to="$REPO_ROOT" "$f")"
            git -C "$REPO_ROOT" checkout HEAD -- "$REL_PATH" 2>/dev/null || rm -f "$f"
        done
        return 1
    }

    # Show warnings.
    # `|| true` (2026-07-03, THE tonight-wide transient-failure root cause):
    # under pipefail, grep exits 1 when the (non-empty) nix stderr contains
    # no warning/error/trace line — killing the step AFTER a successful nix
    # build with only "Step 'build' failed (exit 1)" and no cause. Every
    # "intermittent" build failure tonight (cgc-mcp, gitea, dagu, gha-runner,
    # caddy-l4-image, chat-mattermost, gws-mcp) alternated with whether the
    # dirty-tree warning happened to be present to satisfy the grep.
    if [ -s "$BUILD_LOG" ]; then
        grep -i 'warning\|error\|trace' "$BUILD_LOG" | while IFS= read -r line; do
            log_warn "$line"
        done || true
    fi
    rm -f "$BUILD_LOG"

    # Copy from .result to dist/
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        cp -ra "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    else
        cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    fi
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    # Post-build: restore cloud-data files in src/ to their committed state
    # In CI, cleanup is handled by cloud-builder-ship.sh after all parallel jobs finish
    if [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        for f in $CLOUD_DATA_STAGED; do
            REL_PATH="$(realpath --relative-to="$SERVICE_DIR/../.." "$f")"
            # Restore to committed version (if tracked), otherwise remove
            git -C "$SERVICE_DIR/../.." checkout HEAD -- "$REL_PATH" 2>/dev/null || rm -f "$f"
        done
    fi

    # v2 layout: flake reads 2_configs/dist directly via builtins.readDir;
    # NO duplication into dist/. Legacy v1 flat-dump retained for v1 services.
    IS_V2_ENGINE="false"
    if [ -f "$SRC_DIR/flake.nix" ] && grep -q '_shared/engine.nix' "$SRC_DIR/flake.nix"; then
        IS_V2_ENGINE="true"
        log "v2 engine flake detected — skipping cloud-data injection into dist/"
    fi

    # Include 2_configs/dist/ files in dist/ for runtime use (e.g. C3 API needs topology)
    # Legacy v1 behaviour only; v2 engine handles its own layout.
    if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ "$IS_V2_ENGINE" = "false" ]; then
        CLOUD_DATA_DIR="$SERVICE_DIR/../../2_configs/dist"
        FRONT_DATA_DIR="$SERVICE_DIR/../../front-data"
        REPO_ROOT="$SERVICE_DIR/../.."
        if [ -d "$CLOUD_DATA_DIR" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json "$CLOUD_DATA_DIR"/*.md; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included 2_configs/dist/*.json + *.md in dist/"
        fi
        # Include config.json from repo root (needed by cloud-cgc-mcp)
        if [ -f "$REPO_ROOT/config.json" ]; then
            cp "$REPO_ROOT/config.json" "$DIST_DIR/"
            log "Included config.json in dist/"
        fi
        # Include front-data/*.json if available
        if [ -d "$FRONT_DATA_DIR" ]; then
            for f in "$FRONT_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included front-data/*.json in dist/"
        fi
    fi

    # Source hash for REMOTE_BUILD — TS/JS changes must trigger Docker rebuild
    # dist/ only has docker-compose.yml; source goes via rsync. Without this,
    # the ship hash check sees "unchanged" and skips compose (stale container).
    # `-type f` and parenthesised OR predicates: without them, find matches
    # directories whose name ends in *.js (e.g. node_modules/ipaddr.js/ — a
    # package directory), and sha256sum errors with "Is a directory", which
    # makes xargs return 123 and fails the whole build.
    if [ -n "$DOCKER_IMAGE" ]; then
        find "$SRC_DIR" \
            \( -name '*.ts' -o -name '*.js' -o -name 'Dockerfile' -o -name 'package.json' \) \
            -type f 2>/dev/null \
            | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16 > "$DIST_DIR/.src-hash"
    fi

    # Copy extra source files for on-VM builds (e.g. Rust source for rig)
    EXTRA_COPY="$(get_config_array build.extra_copy)"
    if [ -n "$EXTRA_COPY" ]; then
        echo "$EXTRA_COPY" | while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            # Handle directories (ending with /)
            if [ -d "$SRC_DIR/$pattern" ]; then
                "$INJECT_HEADER" tree "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            elif [ -f "$SRC_DIR/$pattern" ]; then
                "$INJECT_HEADER" file "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            fi
            log "Copied extra: $pattern"
        done
    fi

    # docker-run.sh generation moved to step_compose (compose.custom=true in build.json)

    log "Built files:"
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        find "$DIST_DIR" -type f -o -type l | sed "s|$DIST_DIR/|  |"
    else
        find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
    fi
}
