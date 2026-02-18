# Security Architecture Design - Conversation Log
## Task: 2FA + OAuth2.0 Passwordless Architecture
## Date: 2025-12-08

---

# Initial Request

User requested a security plan for:
- Analytics (Matomo), Mail (Mailu), Photos (Immich)
- GitHub OAuth2.0 + 2FA protection
- Disable native logins (passwordless)
- No public ports, WireGuard only, no public APIs

---

# Plan 1: Authentik (Enterprise)

## Architecture
```
Internet → NPM (:443) → Authentik → WireGuard → Apps
```

## Components
- **Identity Provider**: Authentik (self-hosted)
- **Auth Protocols**: OIDC, LDAP, SAML, RADIUS
- **VPN**: WireGuard (manual configuration)
- **MFA**: TOTP, WebAuthn, SMS, Duo

## Resource Requirements
- RAM: ~1.5-2 GB
- Containers: 5+ (server, worker, PostgreSQL, Redis, LDAP outpost)
- Startup: 30-60 seconds

## Pros
- Full enterprise features (LDAP, SAML, SCIM)
- Detailed audit logs
- Custom auth flows
- User self-service portal
- Multi-tenant support

## Cons
- Heavy resource usage
- Complex setup
- May not fit on OCI micro instance (1GB RAM)

---

# Plan 2: Cloudflare Zero Trust + Tailscale (SaaS)

## Architecture
```
Internet → Cloudflare Edge → Cloudflare Tunnel → Tailscale Mesh → Apps
```

## Components
- **Identity Provider**: Cloudflare Access (SaaS)
- **Tunneling**: Cloudflare Tunnel (cloudflared)
- **Mesh VPN**: Tailscale (managed)
- **WAF**: Cloudflare (built-in)

## Key Features
- **ZERO public ports** (all via tunnel)
- Automatic key rotation
- Device posture checks (WARP)
- Global edge authentication

## Pros
- Simplest setup
- Zero public ports
- Built-in DDoS protection
- Low maintenance

## Cons
- Vendor lock-in (Cloudflare)
- Data flows through third party
- Less customization

---

# Plan 3: Open Source Zero Trust

## Architecture
```
Internet → NGINX (:443) → OAuth2 Proxy → Headscale Mesh → Apps
                 │
            CrowdSec (WAF)
```

## Components
- **Identity Provider**: OAuth2 Proxy (lightweight, 50MB)
- **Reverse Proxy**: NGINX (raw)
- **Mesh VPN**: Headscale (self-hosted Tailscale)
- **WAF**: CrowdSec (community threat intel)

## Resource Requirements
- RAM: ~50 MB (OAuth2 Proxy only)
- Containers: 1 binary
- Startup: < 1 second

## Pros
- 100% open source
- Full data sovereignty
- Minimal resources
- Easy migration to Plan 1 if needed

## Cons
- OAuth2 only (no LDAP/SAML)
- Basic device trust
- Manual audit logs

---

# Comparison: Plan 1 vs Plan 2 vs Plan 3

| Feature | Plan 1 (Authentik) | Plan 2 (Cloudflare) | Plan 3 (Open Source) |
|---------|-------------------|--------------------|--------------------|
| Identity Provider | Self-hosted | SaaS | Self-hosted |
| RAM Usage | 1.5-2 GB | N/A | 50 MB |
| Public Ports | 443 | 0 | 443 |
| Vendor Lock-in | None | High | None |
| Enterprise Features | Full | Limited | Basic |
| Setup Complexity | High | Low | Medium |
| OCI Free Tier Fit | Tight | N/A | Easy |

---

# Security Flaw Reassessment

## Original 10 Flaws Identified

| # | Flaw | Original Severity |
|---|------|-------------------|
| 1 | Mailu admin password in git | Critical |
| 2 | User password in STATUS.md | Critical |
| 3 | OCI relay password exposed | High |
| 4 | Matomo port 8080 public | High |
| 5 | MySQL creds hardcoded | High |
| 6 | No 2FA anywhere | Critical |
| 7 | SMTP/IMAP public | Medium |
| 8 | SSH port 22 open | Medium |
| 9 | No device trust | High |
| 10 | Passwords in docker-compose | High |

## User Corrections (Revised Assessment)

| # | Flaw | User's Point | Revised Severity |
|---|------|--------------|------------------|
| 1 | Mailu password in git | Passwordless = irrelevant | NON-ISSUE (after SSO) |
| 2 | User password in STATUS.md | Passwordless | NON-ISSUE (after SSO) |
| 3 | OCI relay password | OCI requires RSA or pwd+2FA | NON-ISSUE |
| 4 | Matomo port 8080 | Hide behind NPM + OAuth | EASY FIX |
| 5 | MySQL creds | Internal Docker network | NON-ISSUE |
| 6 | No 2FA | Add it | **REAL FLAW** |
| 7 | SMTP/IMAP public | Required for email | ACCEPTABLE |
| 8 | SSH port 22 | Already have WireGuard | ALREADY FIXED |
| 9 | No device trust | Only real flaw | **REAL FLAW** |
| 10 | Passwords in docker-compose | Passwordless structure | NON-ISSUE (after SSO) |

## Actual Remaining Flaws (Only 3)

1. **No 2FA on web apps** → Add OAuth + 2FA
2. **No device trust** → Add with Authentik/OAuth2 Proxy
3. **Matomo exposed on 8080** → Move behind NPM with auth

---

# Revised Risk Assessment

```
ORIGINAL ASSESSMENT (incorrect):
Risk Level: 85% CRITICAL

ACTUAL CURRENT STATE:
Risk Level: 40%
- WireGuard already in place
- Docker internal networks
- OCI has 2FA
- Passwords become irrelevant with SSO

AFTER ADDING OAuth + 2FA:
Risk Level: 10%
```

---

# Final Recommendation

**For single-admin homelab on OCI Free Tier: Plan 3 (OAuth2 Proxy)**

Reasons:
1. Authentik (Plan 1) may OOM on 1GB micro instance
2. Only need GitHub OAuth (no LDAP/SAML)
3. Single admin = no complex policies needed
4. CrowdSec adds WAF protection
5. Headscale easier than manual WireGuard
6. Easy migration path to Authentik if needed later

---

# Enterprise vs Homelab

| Use Case | Recommended |
|----------|-------------|
| Single admin homelab | **Plan 3** |
| Small team (2-5) | Plan 3 |
| Company (10+) | **Plan 1** |
| Compliance (SOC2) | **Plan 1** |
| Privacy-focused | Plan 3 |
| Zero maintenance | Plan 2 |

---

# Implementation Status (2025-12-08)

## OAuth2 Proxy Deployed

**Plan 3** was implemented with OAuth2 Proxy + GitHub OAuth.

### Protected Services

| Service | Domain | Backend | OAuth2 Protected |
|---------|--------|---------|------------------|
| Photos (Immich) | photos.diegonmarcos.com | 10.0.0.2:80 | ✅ Yes |
| Analytics (Matomo) | analytics.diegonmarcos.com | 129.151.228.66:8080 | ✅ Yes |
| n8n | n8n.diegonmarcos.com | 84.235.234.87:5678 | ✅ Yes |
| Auth Endpoint | auth.diegonmarcos.com | oauth2-proxy:4180 | N/A |

### Public Endpoints (Intentionally Unprotected)

| Endpoint | Reason |
|----------|--------|
| `/matomo.js`, `/piwik.js` | Analytics tracking scripts |
| `/webhook/`, `/webhook-test/` | n8n automation webhooks |

### Not Configured

| Service | Domain | Status |
|---------|--------|--------|
| Mail (Mailu) | mail.diegonmarcos.com | DNS exists but no NPM proxy config |

### Architecture

```
User Request
    │
    ▼
Cloudflare (DDoS protection)
    │
    ▼
NPM (Nginx Proxy Manager) :443
    │
    ├──→ /oauth2/auth → OAuth2 Proxy (forward auth)
    │         │
    │         └──→ 401 → /oauth2/sign_in → GitHub OAuth
    │
    └──→ Authenticated → Backend via WireGuard
```

### OAuth2 Proxy Configuration

- **Image**: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
- **Port**: 127.0.0.1:4180 (localhost only)
- **Provider**: GitHub
- **Cookie Domain**: .diegonmarcos.com (SSO across subdomains)
- **Cookie Flags**: HttpOnly, Secure, SameSite=Lax
- **User Restriction**: diegonmarcos GitHub user only

### Security Features

1. **2FA**: GitHub account has 2FA enabled → all apps require GitHub 2FA
2. **Passwordless**: No native app passwords needed (OAuth handles auth)
3. **SSO**: Single session across all subdomains
4. **Session**: 7-day expiry with 1-hour refresh
5. **HTTPS**: Enforced via NPM + Let's Encrypt

---

# Backup 2FA: Authelia (Implemented 2025-12-08)

## Dual Auth Architecture

```
User → auth.diegonmarcos.com
         │
         ├──→ /           → OAuth2 Proxy (GitHub SSO) - PRIMARY
         │
         └──→ /authelia/  → Authelia (Local TOTP 2FA) - BACKUP
```

## When to Use Backup

- GitHub is down
- GitHub OAuth app revoked
- Lost access to GitHub account
- Testing/debugging

## Access Points

| Auth Method | URL | Status |
|-------------|-----|--------|
| GitHub OAuth (Primary) | https://auth.diegonmarcos.com/ | ✅ Active |
| Authelia TOTP (Backup) | https://auth.diegonmarcos.com/authelia/ | ✅ Active |

## Authelia User

- **Username**: diego
- **Password**: (stored in users_database.yml as bcrypt hash)
- **TOTP**: Enroll at first login via QR code
- **Issuer**: diegonmarcos.com

## Authelia Configuration

```
Location: ~/authelia/config/configuration.yml
User DB:  ~/authelia/config/users_database.yml
Storage:  ~/authelia/config/db.sqlite3 (TOTP secrets)
```

## Policy

All protected domains require `two_factor`:
- photos.diegonmarcos.com
- analytics.diegonmarcos.com
- n8n.diegonmarcos.com

---

# Login Pages Updated (2025-12-08)

## Files Updated with Auth Buttons

| File | GitHub SSO | Authelia TOTP |
|------|------------|---------------|
| myphotos/src/index.html | photos.diegonmarcos.com/oauth2/start | auth.diegonmarcos.com/authelia/ |
| mymail/src/index.html | mail.diegonmarcos.com/oauth2/start | auth.diegonmarcos.com/authelia/ |
| cloud/src_vanilla/cloud_dash.html | auth.diegonmarcos.com/oauth2/start | auth.diegonmarcos.com/authelia/ |
| cloud/src_vanilla/index.html | auth.diegonmarcos.com/oauth2/start | auth.diegonmarcos.com/authelia/ |

## Button Styling

- **GitHub SSO**: Dark gray (#24292e) with GitHub logo icon
- **Authelia TOTP**: Navy blue (#1a237e) with shield icon

## Auth Flow

1. User clicks GitHub SSO button
2. Redirects to auth.diegonmarcos.com/oauth2/start
3. OAuth2 Proxy redirects to GitHub OAuth
4. GitHub prompts for 2FA (if enabled)
5. User authenticated, session cookie set
6. Cookie valid for .diegonmarcos.com domain (SSO)

## Backup Flow (Authelia)

1. User clicks Authelia TOTP button
2. Redirects to auth.diegonmarcos.com/authelia/
3. User enters local credentials
4. Authelia prompts for TOTP code
5. User authenticated, session cookie set
