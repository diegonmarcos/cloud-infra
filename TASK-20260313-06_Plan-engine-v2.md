# Plan: _engine.sh v2 — Universal Build Pipeline + Ops API

> **Date**: 2026-03-13
> **Status**: Draft
> **Scope**: `a_solutions/_engine.sh` + `bc-obs_c3-mcp-api/src/api/routes/ops.ts`

---

## Problem

1. `REMOTE_BUILD` is an env var hack, not declarative in build.json
2. `step_docker_remote` bypasses dist/ (rsyncs src/ to temp dir)
3. No `source_code` pattern — services with 100% owned code use ad-hoc workarounds
4. No health check step (only verifies "running", not "healthy")
5. No report step — no record of what was deployed, how long it took, or if it's healthy
6. rig-agentic GHA has `REMOTE_BUILD=true` but it's dead code (no docker section)

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
| `docker.build: "local"` | Same arch (x86→x86) | Can build natively, push to registry |
| `docker.build: "remote"` | Cross arch (x86→ARM) | GHA can't build ARM images |
| `docker.build: "compose"` | Compose handles it | `compose_flags: "--build"` |
| (none) | config_only | No image to build |

`REMOTE_BUILD` env var kept as override for backward compat.

---

## Pipeline Steps

```
STEP 1: BUILD FLAKES (always local)
  │  nix build src/ → dist/docker-compose.yml + configs
  │  OR copy_only: cp src/ → dist/
  │  dist/ = deployment artifact (ALWAYS exists)
  │
  │  If build.source = true:
  │    extra_copy: Dockerfile, source dirs → dist/
  │    pre_build: run scripts in dist/ (e.g. dash/build.sh)
  │
  ▼
STEP 2: BUILD IMAGE LOCAL (if docker.build = "local")
  │  docker buildx build src/ → push to registry
  │  hash check: skip if Dockerfile unchanged
  │  if docker.binary: extract binary → dist/
  │  Runs BEFORE deploy — image goes to registry
  │
  ▼
STEP 3: SECRETS
  │  sops decrypt → dist/.secrets
  │
  ▼
  ── HASH CHECK: skip deploy+compose if dist/ unchanged ──
  │
  ▼
STEP 4: DEPLOY
  │  rsync dist/ → VM (manifest-based, additive)
  │  dist/ has EVERYTHING: compose + configs + source + secrets
  │  One rsync. One dir on VM. No temp dirs.
  │
  ▼
STEP 5: BUILD IMAGE REMOTE (if docker.build = "remote")
  │  ssh VM "cd $DEPLOY_PATH && docker build -t $IMAGE ."
  │  Source is ALREADY on VM from step 4
  │  No temp dir. No separate rsync.
  │  Runs AFTER deploy.
  │
  ▼
STEP 6: DOCKER UP
  │  Image strategy (priority order):
  │    1. binary + Dockerfile.runtime → build lightweight image
  │    2. remote build → image built in step 5
  │    3. compose --build → docker compose up --build
  │    4. image exists locally → use it
  │    5. pull from registry
  │  docker compose up -d
  │  Pre/post hooks
  │
  ▼
STEP 7: HEALTH CHECK
  │  a) Container state: docker compose ps (existing)
  │  b) HTTP health: curl domain from build.json (NEW)
  │  c) Wait for healthy with timeout (NEW)
  │
  ▼
STEP 8: REPORT → POST to C3 API
  │  Collect all step results → POST /ops/deploy-report
  │  (see Ops API section below)
```

---

## Ship Flow Change

```sh
# CURRENT (broken for source_code pattern):
ship)
    step_docker          # remote: rsyncs src/ to temp dir (bypasses dist/)
    step_build           # flake → dist/
    step_secrets
    step_deploy          # rsync dist/ → VM (missing source code!)
    step_compose         # docker up

# NEW:
ship)
    step_build           # flake → dist/ + extra_copy source + pre_build
    step_docker_local    # if docker.build=local: build+push (before deploy)
    step_secrets
    [hash check]
    step_deploy          # rsync dist/ → VM (has EVERYTHING)
    step_docker_remote   # if docker.build=remote: build on VM from $DEPLOY_PATH
    step_compose         # docker up
    step_health          # verify containers + HTTP
    step_report          # POST to C3 API
```

---

## build.json Changes

### c3-mcp-api (source_code + remote build):
```json
{
  "name": "c3-mcp-api",
  "docker": {
    "build": "remote",
    "image": "diegonmarcos/c3-mcp-api",
    "dockerfile": "Dockerfile"
  },
  "build": {
    "source": true,
    "extra_copy": [
      "Dockerfile", "entrypoint.sh",
      "package.json", "package-lock.json", "tsconfig.json",
      "api", "mcp", "dash", "engines", "shared", "skills"
    ],
    "pre_build": ["dash/build.sh"],
    "include_config_json": "true"
  },
  "deploy": {
    "host": "oci-apps",
    "remote_path": "/opt/containers/c3-mcp-api",
    "sequential_restart": "true"
  },
  "secrets": { "escape_dollars": "true" }
}
```

### rig-agentic (source_code + remote build):
```json
{
  "name": "rig-agentic",
  "docker": {
    "build": "remote",
    "dockerfile": "Dockerfile"
  },
  "build": {
    "source": true,
    "extra_copy": ["Cargo.toml", "Cargo.lock", "Dockerfile", "src"]
  },
  "deploy": {
    "host": "oci-apps",
    "remote_path": "/opt/containers/rig-agentic"
  }
}
```

### caddy (binary + local build — unchanged):
```json
{
  "docker": {
    "build": "local",
    "registry": "ghcr.io",
    "image": "diegonmarcos/caddy-custom",
    "dockerfile": "Dockerfile.caddy",
    "binary": "/usr/bin/caddy",
    "binary_name": "caddy-binary"
  }
}
```

### authelia (config_only — unchanged):
```json
{
  "deploy": {
    "host": "gcp-proxy",
    "remote_path": "/opt/containers/authelia"
  }
}
```

Backward compatible: no `docker.build` = current behavior. `REMOTE_BUILD` env var overrides `docker.build`.

---

## _engine.sh Changes

### 1. Read new config fields
```sh
DOCKER_BUILD="$(get_config docker.build)"        # "local"|"remote"|"compose"|""
BUILD_SOURCE="$(get_config build.source)"          # "true"|""
PRE_BUILD="$(get_config_array build.pre_build)"    # ["dash/build.sh"]

# Backward compat: env var overrides build.json
[ "${REMOTE_BUILD:-}" = "true" ] && DOCKER_BUILD="remote"
```

### 2. step_build: add pre_build support
After existing `extra_copy` block:
```sh
# Run pre-build scripts (e.g. dash/build.sh) inside dist/
if [ -n "$PRE_BUILD" ]; then
    echo "$PRE_BUILD" | while IFS= read -r script; do
        [ -z "$script" ] && continue
        log "Running pre_build: $script"
        (cd "$DIST_DIR" && sh "$script")
    done
fi
```

### 3. step_docker_remote: build from $DEPLOY_PATH (no temp dir)
```sh
step_docker_remote() {
    CURRENT_STEP="docker-remote"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    [ -z "$FULL_IMAGE" ] && FULL_IMAGE="$SERVICE_NAME"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"

    log "Building Docker image on $DEPLOY_HOST (from deployed source)"
    ssh $SSH_OPTS "$DEPLOY_HOST" \
        "cd $DEPLOY_PATH && DOCKER_BUILDKIT=1 docker build -t $FULL_IMAGE:latest -f $DOCKERFILE ."

    log "Image built on $DEPLOY_HOST: $FULL_IMAGE:latest"
}
```

### 4. step_docker routing
```sh
step_docker() {
    # Determine build strategy
    BUILD_STRATEGY="$DOCKER_BUILD"
    [ -z "$BUILD_STRATEGY" ] && [ -n "$DOCKER_IMAGE" ] && BUILD_STRATEGY="local"
    [ -z "$BUILD_STRATEGY" ] && return 0  # no docker = skip

    case "$BUILD_STRATEGY" in
        local)  step_docker_local ;;
        remote) ;; # runs after deploy — handled in ship flow
        compose) ;; # handled by compose_flags --build
        *) log "Unknown docker.build: $BUILD_STRATEGY"; return 1 ;;
    esac
}
```

### 5. step_health (NEW)
```sh
step_health() {
    CURRENT_STEP="health"

    # Container state check (existing logic from step_compose, extracted)
    log "Checking container health..."
    CONTAINER_STATUS=$(ssh $SSH_OPTS "$DEPLOY_HOST" \
        "cd $DEPLOY_PATH && docker compose ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null" || true)
    echo "$CONTAINER_STATUS" | while read -r line; do
        log "  $line"
    done

    # HTTP health check (if domain configured)
    DOMAIN="$(get_config domain)"
    if [ -n "$DOMAIN" ]; then
        log "HTTP health: https://$DOMAIN"
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 10 "https://$DOMAIN" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
            log "  HTTP $HTTP_CODE ✓"
            HEALTH_OK="true"
        else
            log_warn "  HTTP $HTTP_CODE ✗"
            HEALTH_OK="false"
        fi
    fi
}
```

### 6. step_report (NEW) → POST to C3 API
```sh
step_report() {
    CURRENT_STEP="report"
    C3_API="https://api.diegonmarcos.com/c3-api"
    REPORT_ENDPOINT="$C3_API/ops/deploy-report"

    REPORT=$(cat <<REPORTEOF
{
    "service": "$SERVICE_NAME",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "git_sha": "$(git -C "$SERVICE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")",
    "git_branch": "$(git -C "$SERVICE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")",
    "build_type": "${BUILD_SOURCE:+source_code}${BUILD_COPY_ONLY:+copy_only}${TERRAFORM_DEPLOY:+terraform}${WRANGLER_DEPLOY:+wrangler}",
    "docker_build": "${DOCKER_BUILD:-none}",
    "deploy_host": "${DEPLOY_HOST:-local}",
    "deploy_path": "${DEPLOY_PATH:-}",
    "steps": {
        "build": "${STEP_BUILD_STATUS:-skipped}",
        "docker": "${STEP_DOCKER_STATUS:-skipped}",
        "secrets": "${STEP_SECRETS_STATUS:-skipped}",
        "deploy": "${STEP_DEPLOY_STATUS:-skipped}",
        "compose": "${STEP_COMPOSE_STATUS:-skipped}",
        "health": "${HEALTH_OK:-unknown}"
    },
    "duration_s": "$SECONDS"
}
REPORTEOF
    )

    log "Deploy report:"
    echo "$REPORT" | sed 's/^/  /'

    # POST to C3 API (best-effort, don't fail ship on report error)
    curl -s -X POST "$REPORT_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$REPORT" >/dev/null 2>&1 || log_warn "Failed to POST report to C3 API"
}
```

### 7. Updated ship flow
```sh
ship)
    SECONDS=0
    step_build;   STEP_BUILD_STATUS="ok"
    step_docker;  STEP_DOCKER_STATUS="ok"   # local only (remote=noop here)
    step_secrets; STEP_SECRETS_STATUS="ok"

    NEW_HASH=$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    OLD_HASH=$(cat "$SERVICE_DIR/.dist-hash" 2>/dev/null || true)

    if [ "$OLD_HASH" = "$NEW_HASH" ] && [ -n "$NEW_HASH" ]; then
        log "Config unchanged — skipping deploy+compose"
        STEP_DEPLOY_STATUS="skipped (unchanged)"
        STEP_COMPOSE_STATUS="skipped (unchanged)"
    elif [ "$WRANGLER_DEPLOY" = "true" ]; then
        step_wrangler
        echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
    elif [ "$TERRAFORM_DEPLOY" = "true" ]; then
        step_terraform
        echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
    else
        step_deploy; STEP_DEPLOY_STATUS="ok"

        # Remote Docker build (AFTER deploy — source is on VM)
        if [ "$DOCKER_BUILD" = "remote" ]; then
            step_docker_remote; STEP_DOCKER_STATUS="ok (remote)"
        fi

        step_compose; STEP_COMPOSE_STATUS="ok"
        echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
    fi

    step_health
    step_report
    ;;
```

---

## C3 API: Ops Endpoints

New route file: `bc-obs_c3-mcp-api/src/api/routes/ops.ts`

### POST /ops/deploy-report
Receives deploy reports from _engine.sh step_report.

```ts
// Store in memory + persist to JSON file
interface DeployReport {
  service: string;
  timestamp: string;
  git_sha: string;
  git_branch: string;
  build_type: string;
  docker_build: string;
  deploy_host: string;
  deploy_path: string;
  steps: Record<string, string>;
  duration_s: number;
}
```

### GET /ops/deploy-report
Returns last N deploy reports (default 50).

### GET /ops/deploy-report/:service
Returns deploy history for a specific service.

### GET /ops/deploy-status
Returns latest deploy status for ALL services (one row per service, most recent deploy).

### Dashboard Integration
Add "Deploys" tab to dash with:
- Table: service | time | sha | build_type | docker_build | duration | steps | health
- Auto-refresh
- Filter by service

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

1. **build.json**: Add `docker.build`, `build.source`, `build.pre_build` to c3-mcp-api + rig-agentic
2. **_engine.sh**: Read new fields, add pre_build, rewrite step_docker_remote, reorder ship flow
3. **_engine.sh**: Add step_health + step_report
4. **C3 API**: Create `ops.ts` route file with deploy-report endpoints
5. **Dashboard**: Add "Deploys" tab
6. **GHA**: Remove REMOTE_BUILD env vars
7. **Test**: Manual `build.sh ship` from local, then GHA push
