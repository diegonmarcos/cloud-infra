# Dual Authentication System Implementation Plan
## Authelia + GitHub OAuth2 + Local TOTP/Passkey

**Document:** PLAN_DualAuth_Security.md
**Status:** READY FOR IMPLEMENTATION
**Date:** 2025-12-09
**Replaces:** 02_IMPLEMENTATION_PLAN.md (OAuth2 Proxy-only)

---

## 1. Architecture Overview

### 1.1 Complete Security Stack

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          SECURITY ARCHITECTURE                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐ │
│  │                        SECRETS MANAGEMENT LAYER                            │ │
│  ├───────────────────────────────────────────────────────────────────────────┤ │
│  │                                                                           │ │
│  │  LOCAL_KEYS (Git-tracked)     Bitwarden Cloud      Vaultwarden (Self-hosted)│
│  │  ───────────────────────      ────────────────     ────────────────────────│ │
│  │  /home/diego/.../LOCAL_KEYS   bitwarden.com        vault.diegonmarcos.com  │ │
│  │                                                                           │ │
│  │  • SSH keys (00_terminal/)    • Browser passwords  • Backup vault         │ │
│  │  • OCI CLI config             • Credit cards       • Self-hosted fallback │ │
│  │  • GCloud CLI config          • TOTP seeds (Aegis) • Full data ownership  │ │
│  │  • GitHub CLI tokens          • Identities         • Offline access       │ │
│  │  • API keys & tokens          • Secure notes       • Emergency access     │ │
│  │  • Cloud infra creds          • Passkeys           • Synced to Bitwarden  │ │
│  │                                                                           │ │
│  │  USE: Terminal/CLI            USE: Daily browser   USE: Backup + Privacy  │ │
│  │  SYNC: Git (encrypted)        SYNC: Cloud          SYNC: Manual export    │ │
│  │                                                                           │ │
│  └───────────────────────────────────────────────────────────────────────────┘ │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐ │
│  │                        AUTHENTICATION LAYER                                │ │
│  ├───────────────────────────────────────────────────────────────────────────┤ │
│  │                                                                           │ │
│  │                         AUTHELIA (Gateway)                                │ │
│  │                    auth.diegonmarcos.com:9091                             │ │
│  │                                                                           │ │
│  │    ┌─────────────────────┐          ┌─────────────────────┐             │ │
│  │    │   PATH 1: GitHub    │    OR    │  PATH 2: Local Auth │             │ │
│  │    │   OAuth2 (OIDC)     │          │  + TOTP/Passkey     │             │ │
│  │    │                     │          │                     │             │ │
│  │    │  • Passwordless SSO │          │  • Username/Password│             │ │
│  │    │  • GitHub's 2FA     │          │  • TOTP (Aegis/BW)  │             │ │
│  │    │  • Enterprise-grade │          │  • WebAuthn/Passkey │             │ │
│  │    └─────────────────────┘          └─────────────────────┘             │ │
│  │                                                                           │ │
│  │                              ▼                                            │ │
│  │                    SSO Session Cookie                                     │ │
│  │                 Domain: .diegonmarcos.com                                 │ │
│  │                                                                           │ │
│  └───────────────────────────────────────────────────────────────────────────┘ │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐ │
│  │                        PROTECTED SERVICES                                  │ │
│  ├───────────────────────────────────────────────────────────────────────────┤ │
│  │                                                                           │ │
│  │  analytics.*  n8n.*  git.*  sync.*  mail.*  vault.*  cloud.*  photos.*  │ │
│  │                                                                           │ │
│  └───────────────────────────────────────────────────────────────────────────┘ │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Dual Auth Flow

```
User wants to access protected service
              │
              ▼
    ┌──────────────────┐
    │ Authelia Gateway │
    │  Login Page      │
    └────────┬─────────┘
             │
      ┌──────┴──────┐
      ▼             ▼
┌──────────┐  ┌──────────────┐
│ GitHub   │  │   Local +    │
│ OAuth2   │  │ TOTP/Passkey │
│          │  │              │
│ (GitHub  │  │ Password from│
│  2FA)    │  │ Bitwarden +  │
│          │  │ TOTP from    │
│          │  │ Aegis/BW     │
└────┬─────┘  └──────┬───────┘
     │               │
     └───────┬───────┘
             ▼
    ┌──────────────────┐
    │  Access Granted  │
    │  SSO to all      │
    │  subdomains      │
    └──────────────────┘
```

---

## 2. Secrets Management Strategy

### 2.1 LOCAL_KEYS Structure

**Location:** `/home/diego/Documents/Git/LOCAL_KEYS/`

```
LOCAL_KEYS/
├── 00_terminal/          # CLI/Terminal access
│   ├── ssh/              # SSH keys (symlinked to ~/.ssh/)
│   ├── oracle/           # OCI CLI config
│   ├── gcloud/           # Google Cloud CLI
│   └── github/           # GitHub CLI tokens
│
├── 02_browser/           # Browser secrets (reference only)
│   ├── passwords/        # → Managed in Bitwarden
│   ├── totp/             # → Aegis + Garmin
│   ├── passkeys/         # → Brave + YubiKey
│   └── certificates/     # Client certs
│
├── 10_identity/          # Personal identity data
├── 11_payment/           # Payment cards
├── 12_notes/             # Documentation
└── recovery/             # Recovery codes
```

### 2.2 Dual Vault Strategy

| Purpose | Primary | Backup | Sync Method |
|---------|---------|--------|-------------|
| **Browser Passwords** | Bitwarden Cloud | Vaultwarden | Manual export/import |
| **TOTP Seeds** | Aegis (phone) | Bitwarden TOTP | Encrypted backup |
| **SSH Keys** | LOCAL_KEYS | Syncthing | Git + Syncthing |
| **API Tokens** | LOCAL_KEYS | Bitwarden Notes | Manual sync |
| **Recovery Codes** | LOCAL_KEYS | Bitwarden Notes | Manual sync |
| **Passkeys** | Brave + YubiKey | - | Hardware-bound |

### 2.3 Vaultwarden Integration

**Vaultwarden** at `vault.diegonmarcos.com`:
- **Purpose:** Self-hosted backup vault
- **VM:** oci-p-flex_1 (84.235.234.87:8081)
- **Protection:** Authelia 2FA required
- **Sync:** Manual export from Bitwarden → import to Vaultwarden
- **Use Case:**
  - When Bitwarden cloud is down
  - Privacy-sensitive passwords
  - Full data ownership/backup

### 2.4 Credential Reference for Authelia

From `LOCAL_KEYS/README.md`:

```bash
# NPM Admin
URL: http://34.55.55.234:81
Email: me@diegonmarcos.com
Password: [in LOCAL_KEYS]

# Gmail SMTP (for Authelia notifications)
Host: smtp.gmail.com
Port: 587
Username: me@diegonmarcos.com
App Password: [in LOCAL_KEYS]

# SSH Access
gcloud compute ssh arch-1 --zone=us-central1-a
ssh -i ~/.ssh/id_rsa ubuntu@84.235.234.87
```

---

## 3. Authelia Configuration

### 3.1 Main Configuration

**File:** `/home/diego/authelia/configuration.yml`

```yaml
###############################################################################
#                   AUTHELIA CONFIGURATION                                      #
#           Dual Auth: GitHub OIDC + Local TOTP/WebAuthn                        #
###############################################################################

server:
  address: 'tcp://0.0.0.0:9091/'

log:
  level: info
  file_path: /config/authelia.log

theme: auto

# TOTP for local auth (seeds stored in Aegis/Bitwarden)
totp:
  disable: false
  issuer: diegonmarcos.com
  algorithm: sha1
  digits: 6
  period: 30

# Passkey/WebAuthn support
webauthn:
  disable: false
  display_name: Diego's Cloud
  attestation_conveyance_preference: indirect
  user_verification: preferred
  timeout: 60s

# Local users (password in Bitwarden, TOTP in Aegis)
authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id

# Session with Redis
session:
  name: authelia_session
  cookies:
    - domain: diegonmarcos.com
      authelia_url: https://auth.diegonmarcos.com
  redis:
    host: authelia-redis
    port: 6379

# Gmail SMTP (credentials from LOCAL_KEYS)
notifier:
  smtp:
    address: 'smtp://smtp.gmail.com:587'
    username: '${SMTP_USERNAME}'
    password: '${SMTP_PASSWORD}'
    sender: 'Authelia <noreply@diegonmarcos.com>'

# Access control
access_control:
  default_policy: deny
  rules:
    # Bypass for Authelia itself
    - domain: auth.diegonmarcos.com
      policy: bypass

    # Bypass for public endpoints
    - domain: analytics.diegonmarcos.com
      resources: ['^/matomo\.(js|php)$']
      policy: bypass

    - domain: n8n.diegonmarcos.com
      resources: ['^/webhook/']
      policy: bypass

    - domain: vault.diegonmarcos.com
      resources: ['^/api/', '^/identity/', '^/icons/', '^/notifications/']
      policy: bypass

    # 2FA required for all protected services
    - domain:
        - analytics.diegonmarcos.com
        - n8n.diegonmarcos.com
        - git.diegonmarcos.com
        - sync.diegonmarcos.com
        - mail.diegonmarcos.com
        - vault.diegonmarcos.com
        - cloud.diegonmarcos.com
        - photos.diegonmarcos.com
      policy: two_factor
      subject: ['user:diego', 'group:admins']
```

### 3.2 Users Database

**File:** `/home/diego/authelia/users_database.yml`

```yaml
# Local user for backup auth (when GitHub unavailable)
# Password: stored in Bitwarden
# TOTP seed: stored in Aegis
users:
  diego:
    disabled: false
    displayname: "Diego"
    password: "$argon2id$v=19$m=65536,t=3,p=4$HASH_FROM_BITWARDEN"
    email: me@diegonmarcos.com
    groups:
      - admins
```

### 3.3 Docker Compose

**File:** `/home/diego/authelia/docker-compose.yml`

```yaml
version: '3.8'

services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    restart: unless-stopped
    environment:
      TZ: Europe/Paris
      AUTHELIA_JWT_SECRET_FILE: /secrets/JWT_SECRET
      AUTHELIA_SESSION_SECRET_FILE: /secrets/SESSION_SECRET
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /secrets/STORAGE_ENCRYPTION_KEY
      AUTHELIA_NOTIFIER_SMTP_USERNAME: ${SMTP_USERNAME}
      AUTHELIA_NOTIFIER_SMTP_PASSWORD: ${SMTP_PASSWORD}
    volumes:
      - ./configuration.yml:/config/configuration.yml:ro
      - ./users_database.yml:/config/users_database.yml:ro
      - authelia_data:/config
      - ./secrets:/secrets:ro
    networks:
      - authelia_network
    ports:
      - "127.0.0.1:9091:9091"
    depends_on:
      - authelia-redis

  authelia-redis:
    image: redis:alpine
    container_name: authelia-redis
    restart: unless-stopped
    volumes:
      - authelia_redis_data:/data
    networks:
      - authelia_network
    ports:
      - "127.0.0.1:6379:6379"

volumes:
  authelia_data:
  authelia_redis_data:

networks:
  authelia_network:
    name: authelia_network
```

---

## 4. NPM Forward Auth Configuration

### 4.1 Authelia Proxy Host

Create `auth.diegonmarcos.com` in NPM:
- Forward: `127.0.0.1:9091`
- SSL: Let's Encrypt
- Force SSL: Yes

### 4.2 Protected Service Template

**Advanced Nginx config for each protected service:**

```nginx
# Authelia forward auth
location /authelia {
    internal;
    set $upstream_authelia http://127.0.0.1:9091/api/authz/forward-auth;
    proxy_pass $upstream_authelia;
    proxy_set_header Host $host;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-Method $request_method;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

location / {
    auth_request /authelia;
    error_page 401 =302 https://auth.diegonmarcos.com/?rd=$scheme://$http_host$request_uri;

    auth_request_set $user $upstream_http_remote_user;
    auth_request_set $groups $upstream_http_remote_groups;
    proxy_set_header Remote-User $user;
    proxy_set_header Remote-Groups $groups;

    proxy_pass $forward_scheme://$server:$port;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

---

## 5. GitHub OAuth App Setup

1. Go to: https://github.com/settings/developers
2. Create "New OAuth App":
   - Name: `Diego's Cloud Auth`
   - Homepage: `https://auth.diegonmarcos.com`
   - Callback: `https://auth.diegonmarcos.com/api/oidc/callback`
3. Save Client ID and Secret to `LOCAL_KEYS` and `.env`

---

## 6. User Setup Flow

### 6.1 Initial Setup

1. **Deploy Authelia** (see Implementation Steps)
2. **Generate password hash:**
   ```bash
   docker run --rm authelia/authelia:latest \
     authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'
   ```
3. **Store password** in Bitwarden under "Authelia Local Account"
4. **Access** https://auth.diegonmarcos.com
5. **First login** prompts TOTP setup
6. **Add TOTP** to Aegis (scan QR code)
7. **Backup TOTP seed** to Bitwarden TOTP field

### 6.2 Adding Passkey

1. Login with password + TOTP
2. Go to Settings → Security Keys
3. Register device (TouchID/YubiKey)
4. Name it ("MacBook TouchID", "YubiKey 5")

### 6.3 Daily Usage

**Option A - GitHub SSO:**
1. Click "Sign in with GitHub"
2. GitHub handles auth + 2FA
3. Done

**Option B - Local + TOTP:**
1. Enter username/password (from Bitwarden autofill)
2. Enter TOTP (from Aegis or Bitwarden)
3. Done

**Option C - Passkey:**
1. Click "Sign in with Passkey"
2. TouchID/YubiKey prompt
3. Done

---

## 7. Implementation Steps

### Phase 1: Preparation

```bash
# SSH to GCP VM
gcloud compute ssh arch-1 --zone us-central1-a

# Backup current state
mkdir -p ~/backups/$(date +%Y%m%d)
docker cp npm:/data/nginx ~/backups/$(date +%Y%m%d)/npm-nginx
```

### Phase 2: Deploy Authelia

```bash
# Create directory
mkdir -p ~/authelia/secrets

# Generate secrets
openssl rand -hex 64 > ~/authelia/secrets/JWT_SECRET
openssl rand -hex 64 > ~/authelia/secrets/SESSION_SECRET
openssl rand -hex 64 > ~/authelia/secrets/STORAGE_ENCRYPTION_KEY
chmod 600 ~/authelia/secrets/*

# Create config files (copy from this plan)
nano ~/authelia/configuration.yml
nano ~/authelia/users_database.yml
nano ~/authelia/docker-compose.yml

# Create .env with SMTP creds from LOCAL_KEYS
nano ~/authelia/.env

# Deploy
cd ~/authelia && docker compose up -d

# Verify
curl http://127.0.0.1:9091/api/health
```

### Phase 3: Configure NPM

1. Create `auth.diegonmarcos.com` proxy host
2. Add forward auth config to each protected service
3. Test login flow

### Phase 4: Setup GitHub OAuth

1. Create OAuth App at github.com
2. Add credentials to .env
3. Restart Authelia
4. Test GitHub SSO

### Phase 5: Setup TOTP + Passkey

1. Login with password
2. Setup TOTP → scan with Aegis
3. Backup seed to Bitwarden
4. Register Passkey (optional)

---

## 8. Credentials to Update in LOCAL_KEYS

After deployment, add to `LOCAL_KEYS/README.md`:

```markdown
### Authelia (2FA Gateway)
- **URL:** https://auth.diegonmarcos.com
- **Admin Port:** Internal only (127.0.0.1:9091)
- **SMTP:** Gmail relay (configured)

**Local User Account:**
- **Username:** diego
- **Password:** [in Bitwarden: "Authelia Local"]
- **TOTP:** [in Aegis: "Authelia"]

**GitHub OAuth App:**
- **Client ID:** [in .env]
- **Client Secret:** [in .env]

**Session Secrets:**
- **Location:** ~/authelia/secrets/ on GCP VM
- **Generated:** [date]
```

---

## 9. Rollback Plan

### Quick Rollback (remove auth)
```bash
# Edit each NPM proxy host, remove Advanced config
# Services become directly accessible (no auth)
```

### Full Rollback
```bash
cd ~/authelia && docker compose down
# Restore from backup if needed
```

### Emergency Access
```bash
# Via WireGuard (bypasses NPM)
wg-quick up wg0
ssh ubuntu@10.0.0.2  # Direct VM access
```

---

## 10. File Locations Summary

```
GCP VM (34.55.55.234):
├── ~/authelia/
│   ├── docker-compose.yml
│   ├── configuration.yml
│   ├── users_database.yml
│   ├── .env
│   └── secrets/

Local Machine:
├── /home/diego/Documents/Git/LOCAL_KEYS/
│   ├── 00_terminal/ssh/         # SSH keys
│   ├── README.md                # All credentials reference
│   └── ...

Oracle VM (84.235.234.87):
├── ~/vault-app/
│   └── docker-compose.yml       # Vaultwarden (backup vault)
```

---

## 11. Security Verification Checklist

| Check | Expected | Pass? |
|-------|----------|-------|
| Authelia login page loads | Yes | [ ] |
| GitHub SSO works | Yes | [ ] |
| Local + TOTP works | Yes | [ ] |
| Passkey works | Yes | [ ] |
| SSO across subdomains | Yes | [ ] |
| Vaultwarden protected | Yes | [ ] |
| Public endpoints bypass | Yes | [ ] |
| LOCAL_KEYS not exposed | Yes | [ ] |
