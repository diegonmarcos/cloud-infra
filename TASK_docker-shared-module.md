# TASK: Shared Docker Policy Module Migration

> **Created**: 2026-03-19
> **Status**: In Progress (35%)
> **Branch**: main

---

## Goal

Replace per-service duplicated docker-compose YAML generation with a shared Nix module (`_shared/docker.nix`) that auto-injects Docker best practices across all 52 cloud services.

## Module: `a_solutions/_shared/docker.nix`

### Exported Functions

| Function | Purpose |
|----------|---------|
| `docker.mkService { ... }` | Generate YAML for one container with auto-injected policies |
| `docker.mkCompose pkgs { ... }` | Generate complete docker-compose.yml |
| `docker.mkDocs pkgs { ... }` | Generate mdBook documentation (replaces ~60 lines per flake) |
| `docker.banner "path"` | DO NOT EDIT header |

### Auto-Injected Policies

| Policy | Default | Escape Hatch |
|--------|---------|-------------|
| `restart` | `unless-stopped` | `restart = "always"` |
| `stop_grace_period` | `30s` | `stopGracePeriod = "60s"` |
| `read_only` | `true` | `skipReadOnly = true` |
| `tmpfs` | `["/tmp"]` | `tmpfs = ["/tmp" "/run"]` |
| `deploy.resources.limits.pids` | `256` | `pidsLimit = 0` to disable |
| `ulimits.nofile` | `65536` | always on |
| `dns` | none | `dns = ["10.0.0.1"]` |
| `logging` | json-file 10m/3 | `skipLogging = true` |
| `security_opt` | `no-new-privileges` | `skipSecurity = true` |
| `cap_drop` | `ALL` | `skipCapDrop = true` + `capAdd` |
| Port validation | reject `0.0.0.0` | `allowPublicPorts = true` |
| `startAfter` | none | sequential boot chain via depends_on |

### Templates: `_shared/templates/`

| Template | Pattern | For |
|----------|---------|-----|
| `app.nix` | Single container web app | vaultwarden, filebrowser, grist, etc. |
| `app-db.nix` | App + PostgreSQL sidecar | hedgedoc, etherpad, nocodb |
| `build-app.nix` | Dockerfile-built service | alerts-api, orchestrator, MCP APIs |

---

## Migration Checklist

### DONE (18/52)

- [x] `aa-sui_affine` (hedgedoc + postgres)
- [x] `aa-sui_code-server`
- [x] `aa-sui_etherpad` (etherpad + postgres)
- [x] `aa-sui_filebrowser`
- [x] `aa-sui_google-workspace-mcp`
- [x] `aa-sui_grist`
- [x] `aa-sui_mailu-mcp`
- [x] `aa-sui_mattermost-mcp`
- [x] `aa-sui_radicale`
- [x] `ab-mic_vaultwarden`
- [x] `ba-clo_hickory-dns`
- [x] `bb-sec_authelia` (authelia + redis, entrypoint, command)
- [x] `bb-sec_caddy` (L4, build context, resource limits)
- [x] `bb-sec_orchestrator`
- [x] `bc-obs_alerts-api`
- [x] `bc-obs_c3-infra-mcp-api`
- [x] `bc-obs_c3-services-mcp-api`
- [x] `bc-obs_dozzle`

### SKIP (2) — no docker-compose

- [ ] `bb-sec_caddy-l4-image` — Dockerfile-only build
- [ ] `bc-obs_cloud-spec` — docs builder

### TODO MEDIUM (19) — 1-2 containers

- [ ] `aa-sui_hedgedoc`
- [ ] `aa-sui_revealmd`
- [ ] `aa-sui_tools-smtp-proxy`
- [ ] `ad-agi_ollama`
- [ ] `ad-agi_ollama-arm`
- [ ] `ad-agi_rig-agentic`
- [ ] `bb-sec_sauron-central`
- [ ] `bc-obs_dagu`
- [ ] `bc-obs_fluent-bit`
- [ ] `bc-obs_matomo`
- [ ] `bc-obs_sauron-forwarder`
- [ ] `bc-obs_syslog-forwarder`
- [ ] `ca-dat_backup-borg`
- [ ] `ca-dat_backup-bup`
- [ ] `ca-dat_backup-gitea`
- [ ] `ca-dat_db-agent`
- [ ] `ca-dat_gitea`
- [ ] `ca-dat_kg-graph`
- [ ] `ca-dat_redis`

### TODO COMPLEX (13) — 3+ containers or special patterns

- [ ] `aa-sui_mattermost-bots` (3 containers)
- [ ] `aa-sui_photoprism` (3 containers, cap_add, devices)
- [ ] `aa-sui_photos-webhook` (2 containers, cap_add)
- [ ] `aa-sui_tools-mailu` (8 containers, full mail stack)
- [ ] `ac-fin_crawlee-cloud` (8 containers, build contexts)
- [ ] `ac-fin_quant-lab-full` (6 containers)
- [ ] `ac-fin_quant-lab-light` (3 containers)
- [ ] `bc-obs_lgtm` (4 containers, user directives)
- [ ] `bc-obs_nocodb` (2 containers, env_file)
- [ ] `bc-obs_ntfy` (3 containers, cap_add)
- [ ] `bc-obs_sauron-lite` (2 containers, logging)
- [ ] `bc-obs_umami` (3 containers, env_file)
- [ ] `bc-obs_windmill` (3 containers, env_file)
- [ ] `ca-dat_postlite` (8 containers)

---

## Bugs Fixed During Migration

| Bug | Fix | Commit |
|-----|-----|--------|
| `pids_limit:` top-level conflicts with `deploy.resources` | Moved to `deploy.resources.limits.pids` | `e549d37` |
| `depends_on = { svc = {}; }` crashes on missing `.condition` | Added `val ? condition` check | `6221d72` |

## Commits

1. `1af28fe` — Add shared Docker policy module + migrate 3 pilots
2. `df8378a` — Migrate 5 services (batch 2: code-server, etherpad, filebrowser, grist, radicale)
3. `e549d37` — Fix pids_limit Compose v2 + add templates + entrypoint/command
4. `6221d72` — Migrate 5 services (batch 3: authelia, orchestrator, alerts-api, dozzle, hickory-dns)
5. *(pending)* — Migrate 5 services (batch 4: c3-infra-mcp-api, c3-services-mcp-api, google-workspace-mcp, mailu-mcp, mattermost-mcp)
