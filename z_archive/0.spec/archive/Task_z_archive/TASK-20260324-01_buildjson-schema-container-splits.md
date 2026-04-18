# TASK: build.json Schema Standardization + One-Folder-Per-Container

> Created: 2026-03-24

## Problem

1. build.json lacks standardized routing — no `port`, no `dns`, no default `app.diegonmarcos.com/{name}` path
2. Multi-container folders (c3-infra-mcp-api, c3-services-mcp-api) prevent proper route definition per container
3. `additional_routes` in build.json is a hack for multi-container folders

## Schema Rules

- [ ] Define new build.json schema: mandatory `port` (number) and `dns` (`{name}.app`)
- [ ] Every container gets two URLs: primary (vanity) + `app.diegonmarcos.com/{name}` (app_hub)
- [ ] `upstream` derived from `{dns}:{port}` — no more hardcoding
- [ ] Delete `additional_routes` from schema
- [ ] Container names: hyphens only (no underscores)
- [ ] Update `parsers/build-json.ts` to read new fields
- [ ] Update `gen-topology.ts` to compute upstream from dns:port
- [ ] Auto-generate app_hub routes in caddy-routes.json
- [ ] Auto-generate Hickory DNS zones from dns field

## Phase 1a: c3-infra-mcp-api split

- [ ] Create `bc-obs_c3-mcp/` (MCP server, owns shared/ + engines/)
- [ ] Create `bc-obs_c3-api/` (REST API, symlinks shared/ + engines/)
- [ ] Decouple `api/index.ts` from MCP HTTP server
- [ ] Split secrets.yaml
- [ ] Update GHA workflows
- [ ] Deploy & verify both services
- [ ] Delete `bc-obs_c3-infra-mcp-api/`

## Phase 1b: c3-services-mcp-api split

- [ ] Create `bc-obs_c3-services-mcp/` (MCP server, owns shared/ + registry/)
- [ ] Create `bc-obs_c3-services-api/` (REST API, symlinks shared/ + registry/)
- [ ] Decouple `api/index.ts` from MCP HTTP server
- [ ] Fix port discrepancy (normalize to 8082)
- [ ] Update GHA workflows
- [ ] Deploy & verify both services
- [ ] Delete `bc-obs_c3-services-mcp-api/`

## Phase 2: Migrate all build.json files to new schema

- [ ] Update all ~30 service build.json files (add port, dns, restructure proxy)
- [ ] Remove manual caddy-routes-fallback.json maintenance
- [ ] Verify all services resolve via app.diegonmarcos.com/{name}
- [ ] Verify Hickory DNS zones generated from dns field

## Phase 3: Tier 1 multi-container splits

- [ ] `bb-sec_caddy` -> caddy + introspect-proxy (different images, independent lifecycles)
- [ ] `bb-sec_sauron-central` -> sauron-central + sauron-api (different processes, different routes)
- [ ] `bc-obs_ntfy` -> ntfy + syslog-bridge + github-rss (3 independent services)
- [ ] `ca-dat_postlite` -> individual per DB target (8 independent containers)

## Phase 4: Tier 2 evaluation (case by case)

- [ ] `bc-obs_windmill` (server + worker) — split for independent scaling?
- [ ] `ac-fin_crawlee-cloud` (api + runner + dashboard + scheduler) — split app components?
- [ ] `aa-sui_mattermost-bots` (mattermost + bots) — bots service is independent
- [ ] `aa-sui_photoprism` (photoprism + rclone) — rclone is independent sync job

## Keep as-is (app + tightly-coupled DB/cache)

- `aa-sui_etherpad` (app + postgres)
- `aa-sui_hedgedoc` (app + postgres)
- `bb-sec_authelia` (authelia + redis)
- `bc-obs_nocodb` (nocodb + db)
- `bc-obs_lgtm` (grafana + loki + tempo + mimir)
