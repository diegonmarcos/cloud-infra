# Service APIs — MCP Coverage Audit

> **Date**: 2026-03-06
> **Updated**: 2026-03-06
> **Status**: Audit complete, implementation pending

---

## Checklist

### Priority MCP tools to add
- [ ] ntfy — push notification API (already used for infra alerts)
- [ ] matomo — analytics queries
- [ ] gitea — repo/issue management
- [ ] ollama — AI inference directly from MCP
- [ ] authelia — user/token management
- [ ] syncthing — sync status/control

### Architecture
- [ ] Route all service APIs through C3 as unified gateway
- [ ] Add C3 wrappers for weak/incomplete APIs (radicale, fluent-bit, postlite)
- [ ] Create C3 APIs for services with none (dozzle, redis, backup-borg, db-agent, caddy, hickory-dns)

---

## App Services

| Service | Domain | VM | Has API | MCP Tool | Spec URL | Notes |
|---------|--------|-----|---------|----------|----------|-------|
| affine | drive-notes-affine.diegonmarcos.com | oci-apps | yes | no | `/api/v1/` | Collaborative docs REST API |
| code-server | ide.diegonmarcos.com | oci-apps | partial | no | — | VS Code Server — no public REST API |
| etherpad | app.diegonmarcos.com/etherpad | oci-apps | yes | no | `/api/1.3.0/` | Full REST API with API key |
| filebrowser | app.diegonmarcos.com/filebrowser | oci-apps | yes | no | `/api/` | File ops REST API |
| grist | sheets.diegonmarcos.com | oci-apps | yes | no | `/api/docs` | Spreadsheet REST API |
| hedgedoc | app.diegonmarcos.com/hedgedoc | oci-apps | yes | no | `/apidoc` | Note collaboration API |
| mailu | mail.diegonmarcos.com | oci-mail | yes | partial (mailu-mcp) | `/api/v1/` | Full admin REST API |
| mattermost | chat.diegonmarcos.com | oci-apps | yes | partial (cloud-mattermost-mcp) | `/api/v4/` | Full REST + WebSocket API |
| photoprism | photos.diegonmarcos.com | oci-apps | yes | no | `/api/v1/` | Photo management REST API |
| radicale | cal.diegonmarcos.com | oci-apps | yes | no | CalDAV/CardDAV | No REST, only CalDAV protocol |
| revealmd | app.diegonmarcos.com/revealmd | oci-apps | no | no | — | Static presenter, no API |
| syncthing | sync.diegonmarcos.com | oci-mail | yes | no | `/rest/` | Full REST API with API key |

---

## Security / Proxy Services

| Service | Domain | VM | Has API | MCP Tool | Spec URL | Notes |
|---------|--------|-----|---------|----------|----------|-------|
| authelia | auth.diegonmarcos.com | gcp-proxy | yes | no | `/api/configuration` | OIDC + user mgmt API |
| caddy | proxy.diegonmarcos.com | gcp-proxy | yes (internal) | no | `localhost:2019/config/` | Admin API, not exposed publicly |
| c3-api | api.diegonmarcos.com/c3-api | oci-apps | yes | yes (primary) | `/c3-api/docs` | Main infra API |
| rust-api | api.diegonmarcos.com/rust-api | oci-apps | yes | partial | `/rust-api/docs` | Legacy, still running |
| vaultwarden | vault.diegonmarcos.com | gcp-proxy | yes | no | `/api/` | Bitwarden-compatible REST API |
| orchestrator | — | oci-apps | yes | no | — | Internal orchestration API |
| sauron-central | — | gcp-proxy | yes | no | — | SIEM/syslog REST API |
| alerts-api | — | gcp-proxy | yes | no | — | Alert aggregation API |
| hickory-dns | — | gcp-proxy | no | no | — | DNS only, no REST API |

---

## Observability / Tools

| Service | Domain | VM | Has API | MCP Tool | Spec URL | Notes |
|---------|--------|-----|---------|----------|----------|-------|
| matomo | analytics.diegonmarcos.com | oci-analytics | yes | no | `/index.php?module=API` | Full analytics REST API |
| nocodb | db.diegonmarcos.com | oci-apps | yes | no | `/api/v1/` | Airtable-like REST API |
| ntfy | rss.diegonmarcos.com | gcp-proxy | yes | no | `/docs` | Push notification API |
| dagu | workflows.diegonmarcos.com | oci-mail | yes | no | `/api/v1/` | DAG scheduler REST API |
| dozzle | app.diegonmarcos.com/dozzle | gcp-proxy | no | no | — | Read-only log viewer, no API |
| lgtm (Grafana) | — | oci-apps | yes | no | `/api/` | Grafana + Loki + Prometheus APIs |
| postlite | — | gcp-proxy | yes | no | `/` | SQLite REST API (WireGuard only) |
| fluent-bit | — | gcp-proxy | yes (internal) | no | `localhost:2020/api/v1/` | Internal metrics/monitoring API |

---

## Data / Storage

| Service | Domain | VM | Has API | MCP Tool | Spec URL | Notes |
|---------|--------|-----|---------|----------|----------|-------|
| gitea | — | oci-apps | yes | no | `/api/swagger` | Full git forge REST API |
| kg-graph | — | oci-apps | yes | no | — | Knowledge graph API |
| redis | — | gcp-proxy | no | no | — | TCP protocol only, no REST |
| db-agent | — | all | no | no | — | Internal backup agent |
| backup-borg | — | oci-apps | no | no | — | CLI only |

---

## AGI / AI

| Service | Domain | VM | Has API | MCP Tool | Spec URL | Notes |
|---------|--------|-----|---------|----------|----------|-------|
| ollama | — | gcp-gpu-embed | yes | no | `/api/` | OpenAI-compatible REST API |
| ollama-arm | — | — | n/a | no | `/api/` | ON HOLD — ran on oci-apps-2, which is decommissioned; no successor host |
| rig-agentic | — | oci-apps | yes | no | — | Agentic pipeline API |

---

## Cloud / External

| Service | Domain | VM | Has API | MCP Tool | Notes |
|---------|--------|-----|---------|----------|-------|
| crawlee-cloud | api.diegonmarcos.com/crawlee | oci-apps | yes | yes (crawlee_*) | Scraping job API |
| cloudflare | — | local | yes | no | External — Cloudflare REST API |
| gcloud | — | local | yes | no | External — GCP REST API |

---

## Summary

| Status | Count | Services |
|--------|-------|----------|
| Has API + MCP tool | 2 | c3-api, crawlee-cloud |
| Has API, partial MCP | 3 | rust-api, mailu (mailu-mcp), mattermost (cloud-mattermost-mcp) |
| Has API, no MCP tool | 19 | affine, etherpad, filebrowser, grist, hedgedoc, photoprism, syncthing, authelia, vaultwarden, matomo, nocodb, ntfy, dagu, gitea, ollama, ollama-arm, postlite, lgtm, rig-agentic |
| No REST API | 8 | radicale, revealmd, caddy (internal), redis, dozzle, hickory-dns, backup-borg, db-agent |

### Priority candidates for new MCP tools
1. **ntfy** — already used for infra alerts, API is live
2. **matomo** — analytics queries useful in agent context
3. **gitea** — repo/issue management
4. **ollama** — AI inference directly from MCP
5. **authelia** — user/token management
6. **syncthing** — sync status/control

---

## Proposal: C3 API as Universal Service Layer

### 1. MCP coverage for all APIs
Every service with a REST API gets MCP tool(s) in `cloud-infra`. No service left uncovered.
Agents should be able to interact with every part of the stack without leaving the MCP context.

### 2. Consolidate all APIs under C3
All service APIs are routed through `api.diegonmarcos.com/c3-api/` as a unified gateway.
Single auth (Authelia bearer), single entry point, single place to add rate limiting / logging / versioning.
Services remain internally reachable at their own ports — C3 just proxies and standardizes.

### 3. C3 as wrapper for weak / incomplete APIs
Some services have poor API design (missing endpoints, bad auth, no pagination, inconsistent responses).
C3 exposes clean, well-designed endpoints that wrap the underlying messy ones.
Examples: radicale (CalDAV → REST wrapper), fluent-bit (internal only → expose via C3), postlite (extend with query builder).

### 4. C3 creates APIs for services that have none
Services with no REST API get a C3-built API:
- **dozzle** — log query endpoint
- **redis** — key/value REST interface
- **backup-borg** — trigger/status endpoints
- **db-agent** — backup job control
- **caddy** — expose admin API securely via C3 (currently internal-only)
- **hickory-dns** — DNS record management REST API
