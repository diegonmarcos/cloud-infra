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

    # Pre-build: update cloud-data submodule + copy files into src/
    # (nix flakes can't see git submodule contents — this bridges the gap)
    CLOUD_DATA_STAGED=""
    if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        # In CI, cloud-builder-ship.sh pre-stages all files before parallel dispatch
        # to avoid git index race conditions. Only do this in local/serial builds.
        CLOUD_DATA_DIR="$SERVICE_DIR/../../I_cloud-data"
        # Auto-update submodule to latest remote
        if [ -f "$SERVICE_DIR/../../.gitmodules" ]; then
            log "Updating cloud-data submodule to latest"
            git -C "$SERVICE_DIR/../.." submodule update --remote --init I_cloud-data 2>/dev/null || true
        fi
        if [ -d "$CLOUD_DATA_DIR" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                BASENAME=$(basename "$f")
                TARGET="$SRC_DIR/$BASENAME"
                # Skip files already committed in src/ — don't overwrite with submodule copy
                if git -C "$SERVICE_DIR/../.." ls-files --error-unmatch "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" >/dev/null 2>&1; then
                    continue
                fi
                cp "$f" "$TARGET"
                git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" 2>/dev/null || true
                CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $TARGET"
            done
            log "Staged I_cloud-data/*.json into src/ for nix build"
        fi
    elif [ "$INCLUDE_CLOUD_DATA" = "true" ]; then
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
            git -C "$REPO_ROOT" reset HEAD "$(realpath --relative-to="$REPO_ROOT" "$f")" 2>/dev/null || true
            rm -f "$f"
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

    # Post-build: unstage and remove cloud-data files from src/
    # In CI, cleanup is handled by cloud-builder-ship.sh after all parallel jobs finish
    if [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        for f in $CLOUD_DATA_STAGED; do
            git -C "$SERVICE_DIR/../.." reset HEAD "$(realpath --relative-to="$SERVICE_DIR/../.." "$f")" 2>/dev/null || true
            rm -f "$f"
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
