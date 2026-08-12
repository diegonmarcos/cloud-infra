# Engine v2 — Universal Build Pipeline + Secrets-First Order

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Draft
> **Merges**: TASK-06 (engine v2) + TASK-07 Phase 4 (engine pipeline reorder)

---

## Checklist

- [ ] Make REMOTE_BUILD declarative in build.json (`docker.build`)
- [ ] Fix step_docker_remote to use dist/ pattern (no temp dir)
- [ ] Add source_code pattern for owned-code services
- [ ] Reorder pipeline: secrets BEFORE build (from TASK-07)
- [ ] Add symlink check in step_secrets (from TASK-07)
- [ ] Preserve .secrets across rm -rf in step_build (from TASK-07)
- [ ] Add step_health post-deploy
- [ ] Add step_report (POST to C3 API)

---

> **Scope**: `a_solutions/_engine.sh` + `bc-obs_c3-mcp-api/src/api/routes/ops.ts`

---

## Problem

1. `REMOTE_BUILD` is an env var hack, not declarative in build.json
2. `step_docker_remote` bypasses dist/ (rsyncs src/ to temp dir)
3. No `source_code` pattern — services with 100% owned code use ad-hoc workarounds
4. No health check step (only verifies "running", not "healthy")
5. No report step — no record of what was deployed
6. Pipeline order `build → secrets` means secrets don't exist during build — breaks universal local/remote pattern
7. With vault symlinks (TASK-sec-02), step_secrets needs to handle broken symlinks gracefully

---

## Service Classification (from build.json)

| Type | Trigger | Examples |
|------|---------|----------|
| config_only | No `docker`, no `build.copy_only` | authelia, ntfy, syncthing, nocodb |
| copy_only | `build.copy_only: true` | cloudflare-worker |
| source_code | `build.source: true` + `build.extra_copy` | c3-mcp-api, rig-agentic |
| binary | `docker.binary` | caddy, rust-api |
| terraform | `deploy.terraform: true` | cloudflare |
| wrangler | `deploy.wrangler: true` | cloudflare-worker |

## Build Location (from build.json)

| Value | When | Why |
|-------|------|-----|
| `docker.build: "local"` | Same arch (x86→x86) | Build natively, push to registry |
| `docker.build: "remote"` | Cross arch (x86→ARM) | GHA can't build ARM images |
| `docker.build: "compose"` | Compose handles it | `compose_flags: "--build"` |
| (none) | config_only | No image to build |

---

## Pipeline (NEW — secrets-first order)

```
STEP 1: SECRETS (moved FIRST — from TASK-07)
  │  sops decrypt → dist/.secrets
  │  Symlink check: if secrets.yaml is a broken symlink (vault not cloned), warn + skip
  │  dist/ now has secrets BEFORE build runs
  │
  ▼
STEP 2: BUILD FLAKES
  │  Preserve .secrets* across rm -rf dist/ (save → clean → restore)
  │  nix build src/ → dist/docker-compose.yml + configs
  │  OR copy_only: cp src/ → dist/
  │  If build.source = true:
  │    extra_copy: Dockerfile, source dirs → dist/
  │    pre_build: run scripts in dist/ (e.g. dash/build.sh)
  │
  ▼
STEP 3: BUILD IMAGE LOCAL (if docker.build = "local")
  │  docker buildx build src/ → push to registry
  │  hash check: skip if Dockerfile unchanged
  │  if docker.binary: extract binary → dist/
  │
  ▼
  ── HASH CHECK: skip deploy+compose if dist/ unchanged ──
  │
  ▼
STEP 4: DEPLOY
  │  rsync dist/ → VM (manifest-based, additive)
  │  dist/ has EVERYTHING: compose + configs + source + secrets
  │
  ▼
STEP 5: BUILD IMAGE REMOTE (if docker.build = "remote")
  │  ssh VM "cd $DEPLOY_PATH && docker build -t $IMAGE ."
  │  Source is ALREADY on VM from step 4
  │
  ▼
STEP 6: DOCKER UP
  │  docker compose up -d
  │
  ▼
STEP 7: HEALTH CHECK (NEW)
  │  Container state + HTTP health check
  │
  ▼
STEP 8: REPORT (NEW) → POST to C3 API
```

**Key change from original TASK-06**: Secrets moved to step 1 (was step 3). This ensures dist/ has both config files (from flake) AND decrypted secrets before deploy — universal for local and remote builds.

---

## Secrets-First Changes (from TASK-07)

### step_secrets: symlink check

```bash
step_secrets() {
    CURRENT_STEP="secrets"

    # Handle vault symlinks (TASK-sec-02)
    if [ -L "$SRC_DIR/secrets.yaml" ] && [ ! -e "$SRC_DIR/secrets.yaml" ]; then
        log_warn "secrets.yaml symlink target missing (vault not cloned?) — skipping"
        return 0
    fi

    # ... existing sops decrypt logic ...
}
```

### step_build: preserve secrets across rm -rf

```bash
step_build() {
    CURRENT_STEP="build"

    # Save secrets if they exist (from step_secrets running first)
    if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/.secrets" ]; then
        _saved=$(mktemp -d)
        cp -a "$DIST_DIR/.secrets" "$_saved/" 2>/dev/null || true
        cp -a "$DIST_DIR/.secrets.d" "$_saved/" 2>/dev/null || true
    fi

    rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"

    # Restore
    if [ -n "${_saved:-}" ] && [ -d "$_saved" ]; then
        cp -a "$_saved/"* "$DIST_DIR/" 2>/dev/null || true
        rm -rf "$_saved"
    fi

    # ... existing nix build logic ...
}
```

---

## New Steps

### step_health

```bash
step_health() {
    CURRENT_STEP="health"

    log "Checking container health..."
    CONTAINER_STATUS=$(ssh $SSH_OPTS "$DEPLOY_HOST" \
        "cd $DEPLOY_PATH && docker compose ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null" || true)
    echo "$CONTAINER_STATUS" | while read -r line; do
        log "  $line"
    done

    DOMAIN="$(get_config domain)"
    if [ -n "$DOMAIN" ]; then
        log "HTTP health: https://$DOMAIN"
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 10 "https://$DOMAIN" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
            log "  HTTP $HTTP_CODE OK"
            HEALTH_OK="true"
        else
            log_warn "  HTTP $HTTP_CODE FAIL"
            HEALTH_OK="false"
        fi
    fi
}
```

### step_report

```bash
step_report() {
    CURRENT_STEP="report"
    C3_API="https://api.diegonmarcos.com/c3-api"

    REPORT=$(cat <<REPORTEOF
{
    "service": "$SERVICE_NAME",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "git_sha": "$(git -C "$SERVICE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")",
    "docker_build": "${DOCKER_BUILD:-none}",
    "deploy_host": "${DEPLOY_HOST:-local}",
    "health": "${HEALTH_OK:-unknown}",
    "duration_s": "$SECONDS"
}
REPORTEOF
    )

    log "Deploy report:"
    echo "$REPORT" | awk '{print "  " $0}'

    curl -s -X POST "$C3_API/ops/deploy-report" \
        -H "Content-Type: application/json" \
        -d "$REPORT" >/dev/null 2>&1 || log_warn "Failed to POST report to C3 API"
}
```

---

## Ship Flow (Final)

```bash
ship)
    SECONDS=0
    step_secrets; STEP_SECRETS_STATUS="ok"      # FIRST (from TASK-07)
    step_build;   STEP_BUILD_STATUS="ok"
    step_docker;  STEP_DOCKER_STATUS="ok"        # local only (remote=noop here)

    NEW_HASH=$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    OLD_HASH=$(cat "$SERVICE_DIR/.dist-hash" 2>/dev/null || true)

    if [ "$OLD_HASH" = "$NEW_HASH" ] && [ -n "$NEW_HASH" ]; then
        log "Config unchanged — skipping deploy+compose"
    elif [ "$WRANGLER_DEPLOY" = "true" ]; then
        step_wrangler
    elif [ "$TERRAFORM_DEPLOY" = "true" ]; then
        step_terraform
    else
        step_deploy
        [ "$DOCKER_BUILD" = "remote" ] && step_docker_remote
        step_compose
    fi

    echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
    step_health
    step_report
    ;;
```

---

## build.json Examples

### c3-mcp-api (source_code + remote build)
```json
{
  "name": "c3-mcp-api",
  "docker": { "build": "remote", "image": "diegonmarcos/c3-mcp-api", "dockerfile": "Dockerfile" },
  "build": {
    "source": true,
    "extra_copy": ["Dockerfile", "entrypoint.sh", "package.json", "package-lock.json", "tsconfig.json", "api", "mcp", "dash", "engines", "shared", "skills"],
    "pre_build": ["dash/build.sh"],
    "include_config_json": "true"
  },
  "deploy": { "host": "oci-apps", "remote_path": "/opt/containers/c3-mcp-api", "sequential_restart": "true" },
  "secrets": { "escape_dollars": "true" }
}
```

### caddy (binary + local build)
```json
{
  "docker": { "build": "local", "registry": "ghcr.io", "image": "diegonmarcos/caddy-custom", "dockerfile": "Dockerfile.caddy", "binary": "/usr/bin/caddy", "binary_name": "caddy-binary" }
}
```

---

## C3 API: Ops Endpoints

New route: `bc-obs_c3-mcp-api/src/api/routes/ops.ts`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ops/deploy-report` | POST | Receive deploy report from _engine.sh |
| `/ops/deploy-report` | GET | Last N deploy reports (default 50) |
| `/ops/deploy-report/:service` | GET | Deploy history for a service |
| `/ops/deploy-status` | GET | Latest deploy status per service |

---

## GHA Changes

Remove `REMOTE_BUILD` env var from workflows (now in build.json):
```yaml
# BEFORE:
- name: Ship c3-api
  env:
    REMOTE_BUILD: "true"
  run: bash a_solutions/bc-obs_c3-mcp-api/build.sh ship

# AFTER:
- name: Ship c3-api
  run: bash a_solutions/bc-obs_c3-mcp-api/build.sh ship
```

---

## Implementation Order

1. build.json: Add `docker.build`, `build.source`, `build.pre_build` to c3-mcp-api + rig-agentic
2. _engine.sh: Secrets-first reorder + symlink check + preserve secrets in step_build
3. _engine.sh: Read new config fields, rewrite step_docker_remote, add step_health + step_report
4. C3 API: Create `ops.ts` route file
5. Dashboard: Add "Deploys" tab
6. GHA: Remove REMOTE_BUILD env vars
7. Test: Manual `build.sh ship` from local, then GHA push
