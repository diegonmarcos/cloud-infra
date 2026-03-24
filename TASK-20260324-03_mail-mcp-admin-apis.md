# TASK: Add Stalwart + SnappyMail admin API tools to mail-mcp

> Created: 2026-03-24

## Goal
mail-mcp currently only has IMAP/SMTP tools. Add admin API tools for both:

### Stalwart Admin API (backend) — in c3-services-mcp
- [x] `stalwart-users` — list all accounts
- [x] `stalwart-user_detail` — get specific account details
- [x] `stalwart-queue` — view mail queue
- [x] `stalwart-queue_action` — retry/cancel queued messages
- [x] `stalwart-config` — read config by prefix
- [x] `stalwart-config_update` — update config key
- [x] `stalwart-metrics` — telemetry/metrics
- [ ] `stalwart-admin-dkim` — DKIM key status (API not available in v0.11.8)
- [ ] `stalwart-admin-tls` — TLS cert status (API not available in v0.11.8)
- [ ] `stalwart-admin-logs` — server logs (requires file tracer config)

Auth: `admin@diegonmarcos.com` via Stalwart REST API (https://10.0.0.3:8443/api/) with -k

### SnappyMail Admin (frontend/webmail) — in c3-services-mcp
- [x] `snappymail-health` — HTTP health + version
- [x] `snappymail-domains` — list configured domains
- [x] `snappymail-domain_config` — read domain IMAP/SMTP config
- [ ] `snappy-admin-plugins` — no REST API (PHP admin panel only)
- [ ] `snappy-admin-login_log` — no REST API

Auth: PHP admin panel (no programmatic REST API available)

## Implementation
- Service: `bc-obs_c3-services-mcp/src/mcp/tools/`
- Files: `stalwart.ts` (7 tools), `snappymail.ts` (3 tools)
- Credentials: `STALWART_ADMIN_PASSWORD` in sops secrets.yaml
- Registered in both `mcp/index.ts` and `mcp/http.ts`
- Registry: replaced `mailu` with `stalwart` + `snappymail` in definitions.ts
