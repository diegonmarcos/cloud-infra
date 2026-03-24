# TASK: Add Stalwart + SnappyMail admin API tools to mail-mcp

> Created: 2026-03-24

## Goal
mail-mcp currently only has IMAP/SMTP tools. Add admin API tools for both:

### Stalwart Admin API (backend)
- [ ] `stalwart-admin-domains` — list/manage domains
- [ ] `stalwart-admin-users` — list/manage user accounts
- [ ] `stalwart-admin-blocked_ips` — list/clear blocked IPs
- [ ] `stalwart-admin-queue` — view/manage mail queue
- [ ] `stalwart-admin-config` — read/update config sections
- [ ] `stalwart-admin-reload` — reload config
- [ ] `stalwart-admin-dkim` — DKIM key status
- [ ] `stalwart-admin-tls` — TLS cert status (ACME)
- [ ] `stalwart-admin-logs` — recent server logs

Auth: `admin@diegonmarcos.com` via Stalwart REST API (https://localhost:8443/api/)

### SnappyMail Admin API (frontend/webmail)
- [ ] `snappy-admin-domains` — configured IMAP/SMTP servers
- [ ] `snappy-admin-config` — read/update SnappyMail config
- [ ] `snappy-admin-plugins` — installed plugins
- [ ] `snappy-admin-login_log` — login history

Auth: SnappyMail admin panel (admin token in .secrets)

## Implementation
- Service: `aa-sui_mail-mcp/src/mcp/tools/`
- Add `stalwart-admin.ts` and `snappy-admin.ts` tool files
- Credentials from container env vars (already in .secrets)
- Follow naming convention: `stalwart-{action}`, `snappy-{action}`
