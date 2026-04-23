# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-container-step-wrangler.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Deploy Cloudflare Worker via wrangler
# Sourced by cloud-ship-container-engine.sh

step_wrangler() {
    CURRENT_STEP="wrangler"
    [ "$WRANGLER_DEPLOY" != "true" ] && { log "No deploy.wrangler -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v wrangler >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
        log_error "wrangler or npx not found. Install: npm install -g wrangler"
        return 1
    fi

    # Source Cloudflare credentials: env (GHA) > vault (local)
    # Wrangler auth priority: CLOUDFLARE_API_TOKEN > CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL
    _gha_key="${CLOUDFLARE_API_KEY:-}"
    _gha_email="${CLOUDFLARE_EMAIL:-}"

    # Clear ALL legacy/conflicting vars first so wrangler sees exactly what we set.
    unset CF_API_TOKEN CF_API_KEY CLOUDFLARE_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL 2>/dev/null || true

    # Try vault first (local dev)
    for cf_env in \
        "$HOME/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env" \
        "/home/diego/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env"; do
        if [ -f "$cf_env" ]; then
            _key=$(grep '^CF_API_KEY=' "$cf_env" | cut -d= -f2)
            _email=$(grep '^CF_API_EMAIL=' "$cf_env" | cut -d= -f2)
            if [ -n "$_key" ] && [ -n "$_email" ]; then
                CLOUDFLARE_API_KEY="$_key"
                CLOUDFLARE_EMAIL="$_email"
                export CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
                log "Loaded Cloudflare Global API Key from vault"
                break
            fi
        fi
    done

    # Fallback to GHA env vars if vault not available (CI runner)
    if [ -z "${CLOUDFLARE_API_KEY:-}" ] && [ -n "$_gha_key" ] && [ -n "$_gha_email" ]; then
        CLOUDFLARE_API_KEY="$_gha_key"
        CLOUDFLARE_EMAIL="$_gha_email"
        export CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
        log "Using Cloudflare credentials from environment (CI)"
    fi

    if [ -z "${CLOUDFLARE_API_KEY:-}" ]; then
        log_error "CLOUDFLARE_API_KEY not found (checked vault + environment)"
        return 1
    fi

    log "Deploying Worker to Cloudflare..."
    cd "$DIST_DIR"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler deploy
    else
        log_error "wrangler not found — install via nix or npm"
        return 1
    fi
    log "Worker deployed to Cloudflare"
}
