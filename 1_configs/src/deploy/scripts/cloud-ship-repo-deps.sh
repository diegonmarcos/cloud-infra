#!/bin/sh
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
. "$CLOUD_ROOT/1_configs/src/deploy/scripts/cloud-ship-lib.sh"

# Install ALL deps from config.json — works on NixOS, Termux (nix), Ubuntu (apt), GHA
cmd_deps() {
    pm=$(detect_pm)
    log "Installing all dependencies from config.json (manager: $pm, nix_method: $DEPS_NIX_METHOD, auto_yes: $DEPS_AUTO_YES)..."

    # Collect missing system binaries
    missing_sys=""
    for bin in $(deps_binaries); do
        command -v "$bin" >/dev/null 2>&1 && continue
        missing_sys="$missing_sys $bin"
    done

    if [ -n "$missing_sys" ]; then
        case "$pm" in
            nix)
                nix_args=""
                for bin in $missing_sys; do
                    pkg=$(deps_pkg_name "$bin" "nix")
                    [ -n "$pkg" ] && nix_args="$nix_args nixpkgs#$pkg"
                done
                if [ -n "$nix_args" ]; then
                    confirm "Install via nix:$nix_args?" || { log "Aborted."; exit 1; }
                    nix_install $nix_args
                fi
                ;;
            apt)
                apt_args=""
                nix_fallback=""
                for bin in $missing_sys; do
                    pkg=$(deps_pkg_name "$bin" "apt")
                    if [ -n "$pkg" ]; then
                        apt_args="$apt_args $pkg"
                    else
                        nix_pkg=$(deps_pkg_name "$bin" "nix")
                        [ -n "$nix_pkg" ] && nix_fallback="$nix_fallback nixpkgs#$nix_pkg"
                    fi
                done
                if [ -n "$apt_args" ]; then
                    confirm "Install via apt:$apt_args?" || { log "Aborted."; exit 1; }
                    log "Apt: installing$apt_args"
                    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $apt_args
                fi
                if [ -n "$nix_fallback" ]; then
                    confirm "Install via nix (no apt pkg):$nix_fallback?" || { log "Aborted."; exit 1; }
                    nix_install $nix_fallback
                fi
                ;;
            none)
                log_error "No supported package manager (nix/apt). Install manually:$missing_sys"
                exit 1
                ;;
        esac
    else
        log "System: all binaries on PATH"
    fi

    # Node modules (engine runtime)
    engine_dir="$ENGINE_DIR"
    if [ -f "$engine_dir/package.json" ]; then
        log "Node: installing engine dependencies..."
        (cd "$engine_dir" && npm install --silent --yes)
    fi

    # Generate cloud-deps.json (consolidated deps from all services)
    if command -v tsx >/dev/null 2>&1 && [ -f "$ENGINES_DIR/gen-deps.ts" ]; then
        log "Generating cloud-deps.json..."
        tsx "$ENGINES_DIR/gen-deps.ts"
    else
        log "SKIP cloud-deps.json (tsx or gen-deps.ts not available)"
    fi

    # Verify
    if check_deps; then
        log "All dependencies installed."
    else
        log_error "Some dependencies still missing after install"
        exit 1
    fi
}

cmd_deps "$@"
