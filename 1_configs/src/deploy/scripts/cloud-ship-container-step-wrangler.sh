# Step: Deploy Cloudflare Worker via wrangler
# Sourced by cloud-ship-container-engine.sh

# Loads CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL into the env.
# Source order: env (GHA) > vault (local). Returns 1 if neither available.
_load_cf_credentials() {
    _gha_key="${CLOUDFLARE_API_KEY:-}"
    _gha_email="${CLOUDFLARE_EMAIL:-}"
    unset CF_API_TOKEN CF_API_KEY CLOUDFLARE_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL 2>/dev/null || true

    for cf_env in \
        "$HOME/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env" \
        "/home/diego/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env"; do
        if [ -f "$cf_env" ]; then
            _key=$(grep '^CF_API_KEY=' "$cf_env" | cut -d= -f2)
            _email=$(grep '^CF_API_EMAIL=' "$cf_env" | cut -d= -f2)
            if [ -n "$_key" ] && [ -n "$_email" ]; then
                CLOUDFLARE_API_KEY="$_key"; CLOUDFLARE_EMAIL="$_email"
                export CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
                return 0
            fi
        fi
    done

    if [ -n "$_gha_key" ] && [ -n "$_gha_email" ]; then
        CLOUDFLARE_API_KEY="$_gha_key"; CLOUDFLARE_EMAIL="$_gha_email"
        export CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
        return 0
    fi
    return 1
}

step_wrangler() {
    CURRENT_STEP="wrangler"
    [ "$WRANGLER_DEPLOY" != "true" ] && { log "No deploy.wrangler -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v wrangler >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
        log_error "wrangler or npx not found. Install: npm install -g wrangler"
        return 1
    fi

    if ! _load_cf_credentials; then
        log_error "CLOUDFLARE_API_KEY not found (checked vault + environment)"
        return 1
    fi
    log "Loaded Cloudflare credentials"

    log "Deploying Worker to Cloudflare..."
    cd "$DIST_DIR"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler deploy
    else
        log_error "wrangler not found — install via nix or npm"
        return 1
    fi
    log "Worker deployed to Cloudflare"

    # ── Declarative secret rotation (sops → wrangler) ─────────────────
    # Pushes every KEY=VALUE in dist/.secrets via `wrangler secret put`
    # (stdin is non-interactive). Drops legacy keys listed in
    # build.json deploy.wrangler_secret_drop[].
    if [ "${WRANGLER_SECRETS_PUSH:-}" = "true" ]; then
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Pushing secrets to Cloudflare Worker (from dist/.secrets)…"
            while IFS='=' read -r _key _val; do
                case "$_key" in ''|'#'*) continue ;; esac
                # strip surrounding quotes if any
                _val="${_val#\"}"; _val="${_val%\"}"
                printf '%s' "$_val" | wrangler secret put "$_key" >/dev/null 2>&1 \
                    && log "  ✓ secret put: $_key" \
                    || log_error "  ✗ secret put failed: $_key"
            done < "$DIST_DIR/.secrets"
        else
            log_warn "deploy.wrangler_secrets=true but dist/.secrets not present — skipping push"
        fi
    fi

    if [ -n "${WRANGLER_SECRET_DROP:-}" ]; then
        log "Dropping legacy Worker secrets…"
        printf '%s\n' "$WRANGLER_SECRET_DROP" | while IFS= read -r _drop; do
            [ -z "$_drop" ] && continue
            # `wrangler secret delete` prompts for confirmation; pipe `y` non-interactively.
            printf 'y\n' | wrangler secret delete "$_drop" >/dev/null 2>&1 \
                && log "  ✓ secret delete: $_drop" \
                || log "  – secret delete: $_drop (already absent)"
        done
    fi
}
