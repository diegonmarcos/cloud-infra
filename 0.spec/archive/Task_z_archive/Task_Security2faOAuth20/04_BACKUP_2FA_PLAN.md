# Backup 2FA Plan: Authelia with TOTP
## Fallback Authentication when GitHub OAuth is unavailable

---

# Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DUAL AUTH ARCHITECTURE                          │
│                                                                     │
│  User Request → NPM                                                 │
│                  │                                                  │
│                  ├──→ PRIMARY: OAuth2 Proxy (GitHub)               │
│                  │         │                                        │
│                  │         └──→ GitHub OAuth + GitHub 2FA          │
│                  │                                                  │
│                  └──→ BACKUP: Authelia (Local)                     │
│                           │                                         │
│                           └──→ Local User + Password + TOTP        │
│                                                                     │
│  Cookie Domain: .diegonmarcos.com (shared between both)            │
└─────────────────────────────────────────────────────────────────────┘
```

---

# Current State

| Component | Status | Location |
|-----------|--------|----------|
| OAuth2 Proxy | ✅ Running | GCP:4180 |
| Authelia | ✅ Running | GCP:9091 |
| NPM | ✅ Running | GCP:443 |
| GitHub OAuth | ✅ Configured | Client: Ov23li... |

---

# Implementation Plan

## Phase 1: Configure Authelia for 2FA

### Step 1.1: Update Authelia Configuration
- [ ] Change policy from `one_factor` to `two_factor`
- [ ] Add all protected domains to access_control
- [ ] Update TOTP issuer name
- [ ] Set proper session domain

### Step 1.2: Create Local User
- [ ] Generate bcrypt password hash
- [ ] Create users_database.yml entry
- [ ] Set user as admin (optional)

### Step 1.3: Restart Authelia
- [ ] Restart container
- [ ] Verify logs show no errors
- [ ] Test access to https://auth.diegonmarcos.com (Authelia)

---

## Phase 2: Configure Dual-Auth in NPM

### Step 2.1: Update auth.diegonmarcos.com
- [ ] Keep pointing to OAuth2 Proxy (primary)
- [ ] Add /authelia path for backup access

### Step 2.2: Create Fallback Endpoint
- [ ] Create authelia-backup.diegonmarcos.com OR
- [ ] Add /backup-login path to protected apps

### Step 2.3: Update Protected Apps
- [ ] Add "Login with Local Account" link to sign-in page
- [ ] Configure Authelia forward auth as alternative

---

## Phase 3: Test Both Auth Methods

### Test 3.1: Primary (GitHub OAuth)
- [ ] Access https://photos.diegonmarcos.com
- [ ] Verify redirect to GitHub
- [ ] Complete GitHub 2FA
- [ ] Verify access granted

### Test 3.2: Backup (Authelia TOTP)
- [ ] Access Authelia login directly
- [ ] Login with local credentials
- [ ] Set up TOTP (scan QR code)
- [ ] Verify 2FA prompt
- [ ] Verify access granted

### Test 3.3: Session Sharing
- [ ] Login via GitHub OAuth
- [ ] Verify cookie set for .diegonmarcos.com
- [ ] Login via Authelia
- [ ] Verify both sessions work

---

# Configuration Files

## Authelia configuration.yml (Updated)

```yaml
server:
  host: 0.0.0.0
  port: 9091

log:
  level: info

totp:
  issuer: diegonmarcos.com
  period: 30
  digits: 6

authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 3
      memory: 65536
      parallelism: 4
      salt_length: 16

session:
  name: authelia_session
  domain: diegonmarcos.com
  secret: <existing-secret>
  expiration: 3600
  inactivity: 300
  remember_me_duration: 30d

regulation:
  max_retries: 3
  find_time: 10m
  ban_time: 15m

storage:
  encryption_key: <existing-key>
  local:
    path: /config/db.sqlite3

access_control:
  default_policy: deny
  rules:
    # Protected apps - require 2FA
    - domain: photos.diegonmarcos.com
      policy: two_factor
    - domain: analytics.diegonmarcos.com
      policy: two_factor
    - domain: mail.diegonmarcos.com
      policy: two_factor
    # Auth endpoint itself
    - domain: auth.diegonmarcos.com
      policy: bypass
```

## users_database.yml

```yaml
users:
  diego:
    displayname: "Diego"
    # Password: <you-choose>
    # Generate with: docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."
    email: me@diegonmarcos.com
    groups:
      - admins
```

---

# Verification Checklist

## Pre-Implementation
- [ ] Backup current Authelia config
- [ ] Backup current NPM configs
- [ ] Note current working state
- [ ] Have rollback plan ready

## Post-Implementation
- [ ] GitHub OAuth still works (primary)
- [ ] Authelia login works (backup)
- [ ] TOTP enrollment works
- [ ] TOTP verification works
- [ ] Protected apps accessible via both methods
- [ ] Session cookies work correctly
- [ ] No conflicts between OAuth2 Proxy and Authelia cookies

---

# Rollback Plan

If something breaks:

```bash
# 1. Restore original Authelia config
ssh diego@34.55.55.234
cp ~/authelia/configuration.yml.backup ~/authelia/configuration.yml
docker restart authelia

# 2. If NPM configs broken
# Restore from backup or re-apply OAuth2-only config

# 3. Verify OAuth2 Proxy still works
curl -sI https://photos.diegonmarcos.com/oauth2/start
```

---

# Security Notes

1. **Password for Authelia user**
   - Use strong password (20+ chars)
   - Store securely (password manager)
   - This is BACKUP only - primary is GitHub

2. **TOTP Secret**
   - Stored in Authelia SQLite DB
   - Backup the TOTP secret/QR code
   - Consider hardware key (WebAuthn) for extra security

3. **When to use backup**
   - GitHub is down
   - GitHub OAuth app revoked
   - Lost access to GitHub account
   - Testing/debugging

---

# File Locations

```
GCP (arch-1):
├── ~/authelia/
│   ├── configuration.yml      # Main config
│   ├── users_database.yml     # Local users
│   └── db.sqlite3             # Sessions, TOTP secrets
├── ~/oauth2-proxy/
│   └── docker-compose.yml     # Primary auth
└── ~/npm/data/nginx/proxy_host/
    ├── 1.conf                 # photos (OAuth2 + Authelia fallback)
    ├── 2.conf                 # auth endpoint
    └── 3.conf                 # analytics (OAuth2 + Authelia fallback)
```

---

# Commands Reference

```bash
# Generate password hash
docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'

# Restart Authelia
docker restart authelia

# Check Authelia logs
docker logs authelia -f

# Test Authelia endpoint
curl -sI https://auth.diegonmarcos.com

# Reload NPM nginx
docker exec npm nginx -s reload
```
