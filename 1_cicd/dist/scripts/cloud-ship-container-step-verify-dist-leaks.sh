# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloud-ship-container-step-verify-dist-leaks.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: refuse a wrangler service whose generated dist/ carries a secret-shaped value
# Sourced by cloud-ship-container-engine.sh
#
# Why (2026-10-01): the Cloudflare worker's wrangler.toml held a signed Authelia
# JWT (C3_BEARER_TOKEN, client cloudflare-health-c3-api) in plaintext. The
# copy-only build copied it into dist/wrangler.toml, the dist was committed, and
# the repo is public. Worker secrets belong in sops → dist/.secrets (gitignored)
# → `wrangler secret put` (step_wrangler); a value in [vars] or anywhere else in
# a tracked dist file is published with the repo.
#
# What is scanned: every file under dist/ that git would TRACK. Ignored files
# (dist/.secrets, dist/.wrangler/) are where decrypted material is supposed to
# live and are skipped — the gate is about what can be committed. Outside a git
# work tree nothing can be committed, so every file is scanned.
#
# Rules: the fleet's ONE declaration, 0_apps/src/root/gitleaks.toml, through the
# same scanner the pre-commit hook runs (0_apps/src/githooks/leak-scan) — its
# token-shape-* rules need only grep, which the cloud-builder image has.
#
# Applies to deploy.wrangler=true services (build.json). Any hit fails the step.

step_verify_dist_leaks() {
    CURRENT_STEP="verify-dist-leaks"
    [ "${WRANGLER_DEPLOY:-}" = "true" ] || return 0
    [ -d "$DIST_DIR" ] || { log_error "verify-dist-leaks: no dist/ at $DIST_DIR — run build first"; return 1; }

    _vdl_root="$(cd "$STEPS_DIR/../../.." && pwd)"
    _vdl_scan="$_vdl_root/0_apps/src/githooks/leak-scan"
    _vdl_rules="$_vdl_root/0_apps/src/root/gitleaks.toml"
    [ -f "$_vdl_scan" ] && [ -f "$_vdl_rules" ] || {
        log_error "verify-dist-leaks: scanner or rules missing ($_vdl_scan, $_vdl_rules) — refusing to call dist/ clean"
        return 1; }

    _vdl_list="$(mktemp)"
    find "$DIST_DIR" -type f | sort > "$_vdl_list.all"
    if git -C "$DIST_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # check-ignore prints the IGNORED ones (a tracked file never counts as
        # ignored, so a dist file already in the index is always scanned).
        git -C "$DIST_DIR" check-ignore --stdin < "$_vdl_list.all" > "$_vdl_list.ign" 2>/dev/null || true
        grep -vxF -f "$_vdl_list.ign" "$_vdl_list.all" > "$_vdl_list" || true
    else
        cp "$_vdl_list.all" "$_vdl_list"
    fi
    _vdl_n="$(wc -l < "$_vdl_list" | tr -d ' ')"

    _vdl_rc=0
    tr '\n' '\0' < "$_vdl_list" | xargs -0 env LEAK_SCAN_CONFIG="$_vdl_rules" sh "$_vdl_scan" --files || _vdl_rc=$?
    rm -f "$_vdl_list" "$_vdl_list.all" "$_vdl_list.ign"

    if [ "$_vdl_rc" -ne 0 ]; then
        log_error "verify-dist-leaks: $SERVICE_NAME dist/ carries a secret-shaped value (above). Move it to src/secrets.yaml (sops) — step_wrangler pushes it with 'wrangler secret put'."
        return 1
    fi
    log "verify-dist-leaks: $_vdl_n trackable dist/ file(s) clean"
}
