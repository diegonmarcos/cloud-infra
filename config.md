
# Container-Nix

Declarative Docker Compose configurations managed via Nix flakes.

> **Auto-generated** from `build.json` files + SSH config. Run `./build.sh config` to regenerate.

## VMs

| VM ID | Alias | WG IP | User | Description |
|-------|-------|-------|------|-------------|
| `oci-E2-f_0` | `oci-mail` | `10.0.0.3` | `ubuntu` | Oracle Free - E2 Micro 0 - Mail Server |
| `oci-E2-f_1` | `oci-analytics` | `10.0.0.4` | `ubuntu` | Oracle Free - E2 Micro 1 - Analytics + Workflows |
| `oci-A1-f_0` | `oci-apps` | `10.0.0.6` | `ubuntu` | Oracle Free - A1 Flex 0 (4 OCPUs / 24GB / 100GB) — Consolidated |
| `oci-A1-p_0` | `oci-apps-2` | `10.0.0.7` | `ubuntu` | Oracle Paid - A1 Flex 0 (8 OCPUs / 32GB) |
| `gcp-T4-p_0` | `gcp-t4` | `10.0.0.8` | `diego` | GCloud Paid - N1 Std 4 + T4 GPU (Spot) - Ollama LLM |
| `gcp-E2-f_0` | `gcp-proxy` | `35.226.147.64` | `diego` | GCloud Free - E2 Micro 0 - Central Proxy + Control |
| `vast-RTX-p_0` | `vast-ollama` | `` | `root` | Vast.ai On-Demand - RTX A4000 (16GB VRAM) - Ollama LLM fallback |

## Services by VM

### oci-mail (`oci-E2-f_0`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|
| `mailu-mcp` | app | - | Mailu mail MCP server — IMAP/SMTP/Admin via MCP protocol |
| `mailu` | app | mail.diegonmarcos.com | Mailu mail server stack (mail.diegonmarcos.com) |
| `smtp-proxy` | app | - | SMTP Relay |
| `syncthing` | mic | sync.diegonmarcos.com | File Sync |
| `dagu` | tools | dagu.diegonmarcos.com | Dagu - Lightweight DAG-based workflow scheduler |
| `syslog-forwarder` | tools | - |  |
| `sauron-lite-micro1` | tools | - | File Integrity Scanner |
| `syslog-forwarder-micro1` | tools | - | Syslog Forwarder |

### oci-analytics (`oci-E2-f_1`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|
| `matomo` | tools | analytics.diegonmarcos.com | Matomo hybrid analytics (oci-analytics) |
| `sauron-forwarder` | tools | - | Alert forwarding to central sauron |
| `windmill` | tools | windmill.diegonmarcos.com | Windmill workflow orchestration (windmill.diegonmarcos.com) |
| `sauron-lite-micro2` | tools | - | File Integrity Scanner |
| `db-agent-micro2` | data | - | Central DB Backup Agent |

### oci-apps (`oci-A1-f_0`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|
| `affine` | app | drive-notes-affine.diegonmarcos.com | AFFiNE Collaborative Workspace (drive-notes-affine.diegonmarcos.com) — deployed via hedgedoc flake |
| `code-server` | app | ide.diegonmarcos.com | VS Code IDE (ide.diegonmarcos.com) |
| `etherpad` | app | pad.diegonmarcos.com | Etherpad collaborative editor (NEW - not deployed yet) |
| `filebrowser` | app | files.diegonmarcos.com | FileBrowser web file manager (NEW - not deployed yet) |
| `grist` | app | grist.diegonmarcos.com | Grist spreadsheet/database (sheets.diegonmarcos.com) |
| `hedgedoc` | app | doc.diegonmarcos.com | Collaborative markdown editor |
| `mattermost-bots` | app | chat.diegonmarcos.com | Mattermost team chat with ntfy bridge and C3 command bot |
| `mattermost-mcp` | app | - | Mattermost MCP server |
| `photoprism` | app | photos.diegonmarcos.com | PhotoPrism AI-powered photo management (oci-flex-1) |
| `photos-webhook` | app | - | PhotoPrism Webhook + S3 Processor |
| `radicale` | app | cal.diegonmarcos.com | Radicale CalDAV/CardDAV server (cal.diegonmarcos.com) |
| `revealmd` | app | slides.diegonmarcos.com | Reveal.js markdown presentations (NEW - not deployed yet) |
| `crawlee-cloud` | fin | api.diegonmarcos.com/crawlee/ | Self-hosted Crawlee Cloud — Apify-compatible scraping platform (API + Runner + Dashboard + Scheduler) |
| `quant-lab-full` | fin | - | Full quant stack: Jupyter + Analytics + ML + Risk + NautilusTrader + Postgres |
| `quant-lab-light` | fin | - | Lightweight quant research: Jupyter + NautilusTrader + Postgres |
| `rig-agentic` | agi | - | Rig Agentic AI - Infrastructure agent with DeepSeek + tool calling via C3 API |
| `orchestrator` | sec | - | Container orchestrator — resource budget management for on-demand services |
| `rust-api` | sec | api.diegonmarcos.com/rust-api | Cloud Rust API (api.diegonmarcos.com — default) |
| `lgtm` | tools | grafana.diegonmarcos.com | LGTM observability stack (Grafana, Loki, Tempo, Mimir) (NEW - not deployed yet) |
| `nocodb` | tools | db.diegonmarcos.com | NocoDB database spreadsheet (nocodb.diegonmarcos.com) |
| `backup-borg` | data | - | Media Backups SSH Server (Borg deduplication) |
| `backup-bup` | data | - | Database Backups SSH Server (bup) |
| `backup-gitea` | data | git.diegonmarcos.com | Self-hosted Gitea for git backups and mirroring |
| `gitea` | data | git.diegonmarcos.com | Self-hosted Git service |
| `kg-graph` | data | - | SurrealDB Hybrid Knowledge Graph - Infrastructure topology + vector search |
| `c3-api` | sec | api.diegonmarcos.com/c3-api | C3 — Cloud Control Center: MCP server + Fastify API (api.diegonmarcos.com) |
| `sauron-lite-flex` | tools | - | File Integrity Scanner |
| `db-agent-flex` | data | - | Central DB Backup Agent |
| `rig` | tools | - | Rig Intelligence Framework — Self-healing orchestrator + GraphRAG |

### oci-apps-2 (`oci-A1-p_0`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|
| `ollama-arm` | agi | - | Ollama LLM server (ARM CPU, 7b models) |

### gcp-t4 (`gcp-T4-p_0`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|
| `ollama` | agi | - | Ollama LLM Server — DeepSeek/Qwen 14B on GCP Spot T4 + Vast.ai fallback |

### gcp-proxy (`gcp-E2-f_0`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|
| `vaultwarden` | mic | vault.diegonmarcos.com | Bitwarden password manager |
| `hickory-dns` | cloud | dns.internal | Internal DNS server for WireGuard mesh (.internal zone) |
| `authelia` | sec | auth.diegonmarcos.com | SSO and 2FA authentication portal |
| `caddy` | sec | proxy.diegonmarcos.com | Caddy reverse proxy (replaces NPM on gcp-proxy + oci-mail) |
| `sauron-central` | sec | - | Central Syslog Collector + SIEM API |
| `alerts-api` | tools | - | Security Alert Aggregation API |
| `dozzle` | tools | logs.diegonmarcos.com | Dozzle - Real-time Docker log viewer |
| `fluent-bit` | tools | - | Log processor and forwarder |
| `ntfy` | tools | rss.diegonmarcos.com | Push notification server |
| `postlite` | data | - | SQLite REST API (WireGuard only) |
| `redis` | data | - | In-memory data store |
| `sauron-lite-gcp` | tools | - | File Integrity Scanner |
| `db-agent-gcp` | data | - | Central DB Backup Agent |

### vast-ollama (`vast-RTX-p_0`)

| Service | Category | Domain | Description |
|---------|----------|--------|-------------|


### Local / All VMs

| Service | Category | Description |
|---------|----------|-------------|
| `cloudflare` | cloud | Cloudflare DNS records and configuration (Terraform) |
| `cloudflare-worker` | cloud | Cloudflare Email Worker - routes inbound email (me@diegonmarcos.com) to Mailu via SMTP proxy |
| `gcloud` | cloud | Google Cloud SDK and tools (local CLI only) |
| `sauron-lite` | tools | File Integrity Scanner (deployed on all VMs) |
| `db-agent` | data | Central DB Backup Agent (deployed on all VMs) |
| `cloud-spec` | tools | Unified Cloud Documentation Portal |

## Services by Category


### Suite (aa-sui_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `affine` | `aa-sui_affine` | oci-apps | drive-notes-affine.diegonmarcos.com | AFFiNE Collaborative Workspace (drive-notes-affine.diegonmarcos.com) — deployed via hedgedoc flake |
| `code-server` | `aa-sui_code-server` | oci-apps | ide.diegonmarcos.com | VS Code IDE (ide.diegonmarcos.com) |
| `etherpad` | `aa-sui_etherpad` | oci-apps | pad.diegonmarcos.com | Etherpad collaborative editor (NEW - not deployed yet) |
| `filebrowser` | `aa-sui_filebrowser` | oci-apps | files.diegonmarcos.com | FileBrowser web file manager (NEW - not deployed yet) |
| `grist` | `aa-sui_grist` | oci-apps | grist.diegonmarcos.com | Grist spreadsheet/database (sheets.diegonmarcos.com) |
| `hedgedoc` | `aa-sui_hedgedoc` | oci-apps | doc.diegonmarcos.com | Collaborative markdown editor |
| `mailu-mcp` | `aa-sui_mailu-mcp` | oci-mail | - | Mailu mail MCP server — IMAP/SMTP/Admin via MCP protocol |
| `mattermost-bots` | `aa-sui_mattermost-bots` | oci-apps | chat.diegonmarcos.com | Mattermost team chat with ntfy bridge and C3 command bot |
| `mattermost-mcp` | `aa-sui_mattermost-mcp` | oci-apps | - | Mattermost MCP server |
| `photoprism` | `aa-sui_photoprism` | oci-apps | photos.diegonmarcos.com | PhotoPrism AI-powered photo management (oci-flex-1) |
| `photos-webhook` | `aa-sui_photos-webhook` | oci-apps | - | PhotoPrism Webhook + S3 Processor |
| `radicale` | `aa-sui_radicale` | oci-apps | cal.diegonmarcos.com | Radicale CalDAV/CardDAV server (cal.diegonmarcos.com) |
| `revealmd` | `aa-sui_revealmd` | oci-apps | slides.diegonmarcos.com | Reveal.js markdown presentations (NEW - not deployed yet) |
| `mailu` | `aa-sui_tools-mailu` | oci-mail | mail.diegonmarcos.com | Mailu mail server stack (mail.diegonmarcos.com) |
| `smtp-proxy` | `aa-sui_tools-smtp-proxy` | oci-mail | - | SMTP Relay |

### Misc (ab-mic_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `syncthing` | `ab-mic_syncthing` | oci-mail | sync.diegonmarcos.com | File Sync |
| `vaultwarden` | `ab-mic_vaultwarden` | gcp-proxy | vault.diegonmarcos.com | Bitwarden password manager |

### Financial (ac-fin_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `crawlee-cloud` | `ac-fin_crawlee-cloud` | oci-apps | api.diegonmarcos.com/crawlee/ | Self-hosted Crawlee Cloud — Apify-compatible scraping platform (API + Runner + Dashboard + Scheduler) |
| `quant-lab-full` | `ac-fin_quant-lab-full` | oci-apps | - | Full quant stack: Jupyter + Analytics + ML + Risk + NautilusTrader + Postgres |
| `quant-lab-light` | `ac-fin_quant-lab-light` | oci-apps | - | Lightweight quant research: Jupyter + NautilusTrader + Postgres |

### AI/Agents (ad-agi_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `ollama` | `ad-agi_ollama` | gcp-t4 | - | Ollama LLM Server — DeepSeek/Qwen 14B on GCP Spot T4 + Vast.ai fallback |
| `ollama-arm` | `ad-agi_ollama-arm` | oci-apps-2 | - | Ollama LLM server (ARM CPU, 7b models) |
| `rig-agentic` | `ad-agi_rig-agentic` | oci-apps | - | Rig Agentic AI - Infrastructure agent with DeepSeek + tool calling via C3 API |

### Cloud Providers (ba-clo_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `cloudflare` | `ba-clo_cloudflare` | local | - | Cloudflare DNS records and configuration (Terraform) |
| `cloudflare-worker` | `ba-clo_cloudflare-worker` | local | - | Cloudflare Email Worker - routes inbound email (me@diegonmarcos.com) to Mailu via SMTP proxy |
| `gcloud` | `ba-clo_gcloud` | local | - | Google Cloud SDK and tools (local CLI only) |
| `hickory-dns` | `ba-clo_hickory-dns` | gcp-proxy | dns.internal | Internal DNS server for WireGuard mesh (.internal zone) |

### Security (bb-sec_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `authelia` | `bb-sec_authelia` | gcp-proxy | auth.diegonmarcos.com | SSO and 2FA authentication portal |
| `caddy` | `bb-sec_caddy` | gcp-proxy | proxy.diegonmarcos.com | Caddy reverse proxy (replaces NPM on gcp-proxy + oci-mail) |
| `orchestrator` | `bb-sec_orchestrator` | oci-apps | - | Container orchestrator — resource budget management for on-demand services |
| `rust-api` | `bb-sec_rust-api` | oci-apps | api.diegonmarcos.com/rust-api | Cloud Rust API (api.diegonmarcos.com — default) |
| `sauron-central` | `bb-sec_sauron-central` | gcp-proxy | - | Central Syslog Collector + SIEM API |
| `c3-api` | `bb-sec_mcp-api-c3` | oci-apps | api.diegonmarcos.com/c3-api | C3 — Cloud Control Center: MCP server + Fastify API (api.diegonmarcos.com) |

### Observability (bc-obs_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `alerts-api` | `bc-obs_alerts-api` | gcp-proxy | - | Security Alert Aggregation API |
| `dagu` | `bc-obs_dagu` | oci-mail | dagu.diegonmarcos.com | Dagu - Lightweight DAG-based workflow scheduler |
| `dozzle` | `bc-obs_dozzle` | gcp-proxy | logs.diegonmarcos.com | Dozzle - Real-time Docker log viewer |
| `fluent-bit` | `bc-obs_fluent-bit` | gcp-proxy | - | Log processor and forwarder |
| `lgtm` | `bc-obs_lgtm` | oci-apps | grafana.diegonmarcos.com | LGTM observability stack (Grafana, Loki, Tempo, Mimir) (NEW - not deployed yet) |
| `matomo` | `bc-obs_matomo` | oci-analytics | analytics.diegonmarcos.com | Matomo hybrid analytics (oci-analytics) |
| `nocodb` | `bc-obs_nocodb` | oci-apps | db.diegonmarcos.com | NocoDB database spreadsheet (nocodb.diegonmarcos.com) |
| `ntfy` | `bc-obs_ntfy` | gcp-proxy | rss.diegonmarcos.com | Push notification server |
| `sauron-forwarder` | `bc-obs_sauron-forwarder` | oci-analytics | - | Alert forwarding to central sauron |
| `sauron-lite` | `bc-obs_sauron-lite` | all | - | File Integrity Scanner (deployed on all VMs) |
| `syslog-forwarder` | `bc-obs_syslog-forwarder` | oci-mail | - |  |
| `windmill` | `bc-obs_windmill` | oci-analytics | windmill.diegonmarcos.com | Windmill workflow orchestration (windmill.diegonmarcos.com) |
| `cloud-spec` | `bc-obs_cloud-spec` | local | - | Unified Cloud Documentation Portal |
| `sauron-lite-micro1` | `bc-obs_sauron-lite` | oci-mail | - | File Integrity Scanner |
| `sauron-lite-micro2` | `bc-obs_sauron-lite` | oci-analytics | - | File Integrity Scanner |
| `sauron-lite-gcp` | `bc-obs_sauron-lite` | gcp-proxy | - | File Integrity Scanner |
| `sauron-lite-flex` | `bc-obs_sauron-lite` | oci-apps | - | File Integrity Scanner |
| `syslog-forwarder-micro1` | `bc-obs_syslog-forwarder` | oci-mail | - | Syslog Forwarder |
| `rig` | `bc-obs_rig-agentic` | oci-apps | - | Rig Intelligence Framework — Self-healing orchestrator + GraphRAG |

### Data & Backups (ca-dat_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| `backup-borg` | `ca-dat_backup-borg` | oci-apps | - | Media Backups SSH Server (Borg deduplication) |
| `backup-bup` | `ca-dat_backup-bup` | oci-apps | - | Database Backups SSH Server (bup) |
| `backup-gitea` | `ca-dat_backup-gitea` | oci-apps | git.diegonmarcos.com | Self-hosted Gitea for git backups and mirroring |
| `db-agent` | `ca-dat_db-agent` | all | - | Central DB Backup Agent (deployed on all VMs) |
| `gitea` | `ca-dat_gitea` | oci-apps | git.diegonmarcos.com | Self-hosted Git service |
| `kg-graph` | `ca-dat_kg-graph` | oci-apps | - | SurrealDB Hybrid Knowledge Graph - Infrastructure topology + vector search |
| `postlite` | `ca-dat_postlite` | gcp-proxy | - | SQLite REST API (WireGuard only) |
| `redis` | `ca-dat_redis` | gcp-proxy | - | In-memory data store |
| `db-agent-gcp` | `ca-dat_db-agent` | gcp-proxy | - | Central DB Backup Agent |
| `db-agent-micro2` | `ca-dat_db-agent` | oci-analytics | - | Central DB Backup Agent |
| `db-agent-flex` | `ca-dat_db-agent` | oci-apps | - | Central DB Backup Agent |


## Native Services

### wireguard

WireGuard VPN mesh — managed via home-manager (not Docker)

- **Hub**: `gcp-E2-f_0` (gcp-proxy)
- **Peers**: oci-E2-f_0, oci-E2-f_1, oci-A1-f_0, oci-A1-p_0, gcp-T4-p_0

## VPS Providers

| Provider | Tier | Type | Instances |
|----------|------|------|-----------|
| Oracle Cloud | Free + Paid | Terraform | oci-E2-f_0, oci-E2-f_1, oci-A1-f_0, oci-A1-p_0 |
| Google Cloud | Free + Paid (Spot) | Terraform | gcp-E2-f_0, gcp-T4-p_0 |
| Amazon Web Services | Exploration | Terraform |  |
| Vast.ai | On-demand rental | Manual rental | vast-RTX-p_0 |

## Archived

See `a_solutions/z_archive/` for decommissioned services.
