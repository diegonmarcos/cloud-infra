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
        cp -r "$SRC_DIR/"* "$DIST_DIR/"
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

    # Pre-build: ensure cloud-data is available in src/ for nix build
    # Nix flakes can't see git submodule content, so symlinks to I_cloud-data/
    # must be resolved to real files before nix build. Symlinks in src/ serve as
    # declarative markers — the engine detects them and copies the real data.
    #
    # Detection: if src/ has cloud-data symlinks OR include_cloud_data=true
    CLOUD_DATA_STAGED=""
    CLOUD_DATA_DIR="$SERVICE_DIR/../../I_cloud-data"
    HAS_CLOUD_DATA_SYMLINKS=false

    # Check if src/ has any cloud-data symlinks
    for f in "$SRC_DIR"/cloud-data-*.json; do
        [ -L "$f" ] && HAS_CLOUD_DATA_SYMLINKS=true && break
    done

    # Always update submodule to latest
    if [ -f "$SERVICE_DIR/../../.gitmodules" ] && { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_CLOUD_DATA_SYMLINKS" = "true" ]; }; then
        log "Updating cloud-data submodule to latest"
        git -C "$SERVICE_DIR/../.." submodule update --remote --init I_cloud-data 2>/dev/null || true
    fi

    if { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_CLOUD_DATA_SYMLINKS" = "true" ]; } && [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        if [ -d "$CLOUD_DATA_DIR" ]; then
            # Resolve symlinks to real files (nix can't follow symlinks into submodules)
            for f in "$SRC_DIR"/cloud-data-*.json "$SRC_DIR"/_cloud-data-*.json; do
                [ -L "$f" ] || continue
                REAL_TARGET=$(readlink -f "$f")
                if [ -f "$REAL_TARGET" ]; then
                    rm "$f"
                    cp "$REAL_TARGET" "$f"
                    git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$f")" 2>/dev/null || true
                    CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $f"
                fi
            done
            # Always refresh cloud-data files from I_cloud-data when include_cloud_data=true
            # (was: skip if file existed — caused stale data to persist forever)
            if [ "$INCLUDE_CLOUD_DATA" = "true" ]; then
                for f in "$CLOUD_DATA_DIR"/*.json; do
                    [ -f "$f" ] || continue
                    BASENAME=$(basename "$f")
                    TARGET="$SRC_DIR/$BASENAME"
                    # Skip only if target is a symlink (already handled by resolve-symlinks pass above)
                    [ -L "$TARGET" ] && continue
                    cp "$f" "$TARGET"
                    git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" 2>/dev/null || true
                    CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $TARGET"
                done
            fi
            log "Resolved cloud-data for nix build (${HAS_CLOUD_DATA_SYMLINKS:+symlinks}${INCLUDE_CLOUD_DATA:+ +flag})"
        fi
    elif { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_CLOUD_DATA_SYMLINKS" = "true" ]; }; then
        log "cloud-data already pre-staged by CI — skipping"
    fi

    # build.json: src/build.json is a symlink to ../build.json (root is source of truth)
    if [ -f "$SERVICE_DIR/build.json" ] && [ ! -L "$SRC_DIR/build.json" ]; then
        ln -sf ../build.json "$SRC_DIR/build.json"
        git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$SRC_DIR/build.json")" 2>/dev/null || true
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
        cat "$BUILD_LOG" >&2
        rm -f "$BUILD_LOG"
        for f in $CLOUD_DATA_STAGED; do
            REL_PATH="$(realpath --relative-to="$REPO_ROOT" "$f")"
            git -C "$REPO_ROOT" checkout HEAD -- "$REL_PATH" 2>/dev/null || rm -f "$f"
        done
        return 1
    }

    # Show warnings
    if [ -s "$BUILD_LOG" ]; then
        grep -i 'warning\|error\|trace' "$BUILD_LOG" | while IFS= read -r line; do
            log_warn "$line"
        done
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

    # Carry over docker source hash from step_docker (if image was rebuilt)
    if [ -f "$SERVICE_DIR/.docker-src-hash-new" ]; then
        mv "$SERVICE_DIR/.docker-src-hash-new" "$DIST_DIR/.docker-src-hash"
    fi

    # Include I_cloud-data/ files in dist/ for runtime use (e.g. C3 API needs topology)
    if [ "$INCLUDE_CLOUD_DATA" = "true" ]; then
        CLOUD_DATA_DIR="$SERVICE_DIR/../../I_cloud-data"
        FRONT_DATA_DIR="$SERVICE_DIR/../../front-data"
        REPO_ROOT="$SERVICE_DIR/../.."
        if [ -d "$CLOUD_DATA_DIR" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json "$CLOUD_DATA_DIR"/*.md; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included I_cloud-data/*.json + *.md in dist/"
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
    if [ -n "$DOCKER_IMAGE" ]; then
        find "$SRC_DIR" -name '*.ts' -o -name '*.js' -o -name 'Dockerfile' -o -name 'package.json' 2>/dev/null \
            | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16 > "$DIST_DIR/.src-hash"
    fi

    # Copy extra source files for on-VM builds (e.g. Rust source for rig)
    EXTRA_COPY="$(get_config_array build.extra_copy)"
    if [ -n "$EXTRA_COPY" ]; then
        echo "$EXTRA_COPY" | while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            # Handle directories (ending with /)
            if [ -d "$SRC_DIR/$pattern" ]; then
                cp -r "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            elif [ -f "$SRC_DIR/$pattern" ]; then
                cp "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
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
