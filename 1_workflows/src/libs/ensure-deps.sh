#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Shared library: dep self-bootstrap                               ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   . "$LIB_DIR/ensure-deps.sh"                                    ║
# ║   ensure_node_deps     # tsx + yaml + nunjucks etc.              ║
# ║   ensure_jq            # jq                                      ║
# ║   ensure_sops          # sops + age                              ║
# ║   ensure_terraform     # terraform                               ║
# ║   ensure_wrangler      # wrangler (npm)                          ║
# ║                                                                  ║
# ║ Why: today's outage hit "tsx not found", "yaml ESM resolution",  ║
# ║ "node_modules/.bin not on PATH" — three separate iterations of   ║
# ║ the same class. Engines should self-bootstrap their toolchain    ║
# ║ when the host doesn't provide it (bare GHA runner, fresh clone,  ║
# ║ dev laptop). cloud-builder image already has everything; this is ║
# ║ for the hosts that don't.                                        ║
# ║                                                                  ║
# ║ Each function is idempotent + cheap on second call (early-return ║
# ║ when the dep is already present). Data-driven from config.json:  ║
# ║ .deps where possible.                                            ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guard against double-sourcing.
[ "${_ENSURE_DEPS_LOADED:-}" = "1" ] && return 0
_ENSURE_DEPS_LOADED=1

# Source companion libs without circular issue.
_ed_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$_ed_lib_dir/cloud-paths.sh" ] && . "$_ed_lib_dir/cloud-paths.sh"

# log/log_error if not already defined (engine-traps.sh defines them too).
if ! command -v log >/dev/null 2>&1; then
    log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
fi
if ! command -v log_error >/dev/null 2>&1; then
    log_error() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1" >&2; }
fi

# ── Node-side: tsx + yaml + nunjucks (engine TypeScript runtime) ──
# Installs at $CLOUD_ROOT/node_modules so tsx's ESM resolver finds
# packages via normal node_modules walk-up from any subdir.
ensure_node_deps() {
    if command -v tsx >/dev/null 2>&1; then
        return 0
    fi
    _ed_root="${CLOUD_ROOT:-$(cloud_paths_root 2>/dev/null)}"
    if [ -z "$_ed_root" ]; then
        log_error "ensure_node_deps: cannot locate CLOUD_ROOT"
        return 1
    fi
    if [ -x "$_ed_root/node_modules/.bin/tsx" ]; then
        export PATH="$_ed_root/node_modules/.bin:$PATH"
        return 0
    fi
    if ! command -v npm >/dev/null 2>&1; then
        log_error "ensure_node_deps: npm not found — node 18+ required on host"
        return 1
    fi
    log "ensure_node_deps: bootstrapping engine deps at $_ed_root/node_modules"
    _ed_pkgs=""
    if [ -f "$_ed_root/config.json" ] && command -v jq >/dev/null 2>&1; then
        _ed_pkgs=$(jq -r '.deps.node.required[]?' "$_ed_root/config.json" 2>/dev/null | tr '\n' ' ')
    fi
    [ -z "$_ed_pkgs" ] && _ed_pkgs="tsx yaml nunjucks ajv ajv-formats"
    (
        cd "$_ed_root" && npm install --silent --no-save $_ed_pkgs
    ) || {
        log_error "ensure_node_deps: npm install failed (pkgs=$_ed_pkgs)"
        return 1
    }
    export PATH="$_ed_root/node_modules/.bin:$PATH"
}

# ── jq (heavy use across engines for JSON queries) ──
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    log "ensure_jq: installing jq"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq >/dev/null 2>&1 || true
        sudo apt-get install -y -qq jq >/dev/null 2>&1
    elif command -v nix >/dev/null 2>&1; then
        nix profile install nixpkgs#jq >/dev/null 2>&1
    fi
    command -v jq >/dev/null 2>&1
}

# ── sops + age (secrets decrypt) ──
ensure_sops() {
    command -v sops >/dev/null 2>&1 && return 0
    log "ensure_sops: installing sops"
    if command -v nix >/dev/null 2>&1; then
        nix profile install nixpkgs#sops nixpkgs#age >/dev/null 2>&1
    elif command -v curl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        curl -fsSL -o /tmp/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 \
            && chmod +x /tmp/sops && sudo mv /tmp/sops /usr/local/bin/sops
    fi
    command -v sops >/dev/null 2>&1
}

# ── terraform (used by ship-terraform engine) ──
ensure_terraform() {
    command -v terraform >/dev/null 2>&1 && return 0
    log "ensure_terraform: installing terraform"
    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        curl -fsSL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip \
            && unzip -o /tmp/tf.zip -d /tmp >/dev/null \
            && sudo mv /tmp/terraform /usr/local/bin/terraform
    fi
    command -v terraform >/dev/null 2>&1
}

# ── wrangler (Cloudflare Workers deploy) ──
ensure_wrangler() {
    command -v wrangler >/dev/null 2>&1 && return 0
    log "ensure_wrangler: installing wrangler (npm)"
    if command -v npm >/dev/null 2>&1; then
        # wrangler is a CLI-with-binary, so global install works (unlike yaml/nunjucks).
        npm install -g --silent wrangler >/dev/null 2>&1
    fi
    command -v wrangler >/dev/null 2>&1
}
