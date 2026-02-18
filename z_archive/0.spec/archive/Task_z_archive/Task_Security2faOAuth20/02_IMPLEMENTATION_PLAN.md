# Implementation Plan: OAuth2 Proxy + 2FA
## Chosen Solution: Plan 3 (Open Source Lightweight)
## Status: IMPLEMENTED - 2025-12-08

---

# Prerequisites

- [x] GitHub account with 2FA enabled
- [x] Access to GCP VM (arch-1)
- [x] NPM (Nginx Proxy Manager) running
- [x] WireGuard mesh configured

---

# Phase 1: GitHub OAuth App Setup

## Step 1.1: Create OAuth Application

1. Go to: https://github.com/settings/developers
2. Click "New OAuth App"
3. Fill in:
   ```
   Application name: Cloud Dashboard Auth
   Homepage URL: https://auth.diegonmarcos.com
   Authorization callback URL: https://auth.diegonmarcos.com/oauth2/callback
   ```
4. Save Client ID and Client Secret

## Step 1.2: Verify GitHub 2FA

```bash
# Ensure your GitHub account has 2FA enabled
# Settings → Password and authentication → Two-factor authentication
```

---

# Phase 2: Deploy OAuth2 Proxy on GCP

## Step 2.1: Create Directory Structure

```bash
ssh diego@34.55.55.234

mkdir -p ~/oauth2-proxy
cd ~/oauth2-proxy
```

## Step 2.2: Create Docker Compose

```yaml
# ~/oauth2-proxy/docker-compose.yml
version: '3.8'

services:
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: oauth2-proxy
    restart: unless-stopped
    ports:
      - "127.0.0.1:4180:4180"
    environment:
      # Provider
      OAUTH2_PROXY_PROVIDER: github
      OAUTH2_PROXY_CLIENT_ID: ${GITHUB_CLIENT_ID}
      OAUTH2_PROXY_CLIENT_SECRET: ${GITHUB_CLIENT_SECRET}

      # Cookie
      OAUTH2_PROXY_COOKIE_SECRET: ${COOKIE_SECRET}
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_COOKIE_DOMAINS: ".diegonmarcos.com"
      OAUTH2_PROXY_COOKIE_SAMESITE: "lax"

      # Auth settings
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE: /config/allowed_emails.txt

      # URLs
      OAUTH2_PROXY_REDIRECT_URL: https://auth.diegonmarcos.com/oauth2/callback
      OAUTH2_PROXY_UPSTREAMS: "static://200"

      # Network
      OAUTH2_PROXY_HTTP_ADDRESS: "0.0.0.0:4180"
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"

      # Session
      OAUTH2_PROXY_COOKIE_REFRESH: "1h"
      OAUTH2_PROXY_COOKIE_EXPIRE: "24h"

      # Skip auth for health check
      OAUTH2_PROXY_SKIP_AUTH_ROUTES: "^/ping$"
    volumes:
      - ./config:/config:ro
    networks:
      - proxy-network

networks:
  proxy-network:
    external: true
```

## Step 2.3: Create Environment File

```bash
# ~/oauth2-proxy/.env

# From GitHub OAuth App
GITHUB_CLIENT_ID=Ov23li...
GITHUB_CLIENT_SECRET=...

# Generate with: openssl rand -base64 32 | tr -d '\n'
COOKIE_SECRET=...
```

## Step 2.4: Create Allowed Emails

```bash
# ~/oauth2-proxy/config/allowed_emails.txt
your-email@gmail.com
```

## Step 2.5: Start OAuth2 Proxy

```bash
cd ~/oauth2-proxy
docker-compose up -d
docker-compose logs -f
```

---

# Phase 3: Configure NPM Forward Auth

## Step 3.1: Create Auth Proxy Host

In NPM, create new proxy host:
```
Domain: auth.diegonmarcos.com
Forward Hostname: 127.0.0.1
Forward Port: 4180
SSL: Request new certificate (Let's Encrypt)
Force SSL: Yes
```

## Step 3.2: Configure Protected Apps

For each app (Matomo, Mailu webmail, Immich), add Advanced config:

### Matomo (analytics.diegonmarcos.com)

```nginx
# Advanced → Custom Nginx Configuration

# OAuth2 Proxy endpoints
location /oauth2/ {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Auth-Request-Redirect $request_uri;
}

location = /oauth2/auth {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

# Main location with auth
location / {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    # Pass user info to backend
    auth_request_set $user $upstream_http_x_auth_request_user;
    auth_request_set $email $upstream_http_x_auth_request_email;
    proxy_set_header X-User $user;
    proxy_set_header X-Email $email;

    # Proxy to Matomo (via WireGuard)
    proxy_pass http://10.0.0.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Public tracking endpoints (no auth needed)
location ~ ^/(matomo|piwik)\.(js|php)$ {
    proxy_pass http://10.0.0.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

### Mailu Webmail (mail.diegonmarcos.com)

```nginx
# Advanced → Custom Nginx Configuration

location /oauth2/ {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Auth-Request-Redirect $request_uri;
}

location = /oauth2/auth {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

location / {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    auth_request_set $user $upstream_http_x_auth_request_user;
    auth_request_set $email $upstream_http_x_auth_request_email;
    proxy_set_header X-User $user;
    proxy_set_header X-Email $email;

    # Proxy to Mailu (via WireGuard)
    proxy_pass https://10.0.0.2:443;
    proxy_set_header Host $host;
    proxy_ssl_verify off;
}
```

### Immich (photos.diegonmarcos.com)

```nginx
# Advanced → Custom Nginx Configuration

location /oauth2/ {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Auth-Request-Redirect $request_uri;
}

location = /oauth2/auth {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

location / {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    auth_request_set $user $upstream_http_x_auth_request_user;
    auth_request_set $email $upstream_http_x_auth_request_email;
    proxy_set_header X-User $user;
    proxy_set_header X-Email $email;

    # Proxy to Immich (via WireGuard)
    proxy_pass http://10.0.0.3:2283;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;

    # WebSocket support
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}

# Immich API (for mobile app - may need separate auth handling)
location /api {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    proxy_pass http://10.0.0.3:2283;
    proxy_set_header Host $host;
}
```

---

# Phase 4: Lock Down Ports

## Step 4.1: Bind Matomo to Localhost

```yaml
# On OCI VM - Update matomo docker-compose.yml
services:
  matomo:
    ports:
      - "127.0.0.1:8080:80"  # Was: "8080:80"
```

```bash
docker-compose down && docker-compose up -d
```

## Step 4.2: Verify No Public Exposure

```bash
# From external machine
nmap -p 8080 <OCI_PUBLIC_IP>
# Should show: filtered or closed
```

---

# Phase 5: Testing

## Test 1: OAuth Flow

```bash
# 1. Open browser in incognito
# 2. Go to https://analytics.diegonmarcos.com
# 3. Should redirect to GitHub login
# 4. After GitHub auth, should redirect back to Matomo
# 5. Check for X-User header in Matomo logs
```

## Test 2: 2FA Verification

```bash
# 1. Log out of GitHub
# 2. Try accessing protected app
# 3. GitHub should prompt for 2FA
# 4. Only after 2FA should access be granted
```

## Test 3: Unauthorized User

```bash
# 1. Use different GitHub account (not in allowed_emails.txt)
# 2. Should get "Forbidden" after GitHub auth
```

## Test 4: Direct Port Access

```bash
# Try to access Matomo directly (should fail)
curl http://<OCI_IP>:8080
# Expected: Connection refused or timeout
```

## Test 5: Session Expiry

```bash
# 1. Wait 24 hours (or set shorter expiry for testing)
# 2. Refresh page
# 3. Should require re-authentication
```

---

# Phase 6: Security Verification Checklist

## Before Implementation

| Check | Status | Notes |
|-------|--------|-------|
| Matomo accessible on port 8080 | [ ] | Should be YES (current flaw) |
| Apps have native login | [ ] | Should be YES |
| No 2FA on web apps | [ ] | Should be YES |
| GitHub 2FA enabled | [ ] | Required |

## After Implementation

| Check | Expected | Actual | Pass? |
|-------|----------|--------|-------|
| Matomo port 8080 blocked | Blocked | | [ ] |
| OAuth redirect works | Yes | | [ ] |
| GitHub 2FA required | Yes | | [ ] |
| Unauthorized user blocked | Yes | | [ ] |
| Session cookie secure | Yes | | [ ] |
| HTTPS enforced | Yes | | [ ] |
| WireGuard still works | Yes | | [ ] |
| Mobile apps work | Yes | | [ ] |

---

# Rollback Plan

If something breaks:

```bash
# 1. Remove OAuth2 Proxy
cd ~/oauth2-proxy
docker-compose down

# 2. Remove NPM advanced configs
# In NPM UI, clear custom nginx config for each app

# 3. Restore Matomo port binding
# Change back to "8080:80"

# 4. Restart NPM
docker restart npm
```

---

# Maintenance

## Monthly Tasks

- [ ] Check OAuth2 Proxy logs for errors
- [ ] Verify GitHub OAuth app still active
- [ ] Review allowed_emails.txt
- [ ] Check certificate expiry

## Security Updates

```bash
# Update OAuth2 Proxy
cd ~/oauth2-proxy
docker-compose pull
docker-compose up -d
```

---

# File Locations

```
GCP (arch-1):
├── ~/oauth2-proxy/
│   ├── docker-compose.yml
│   ├── .env (secrets)
│   └── config/
│       └── allowed_emails.txt

NPM:
├── Proxy Host: auth.diegonmarcos.com → 127.0.0.1:4180
├── Proxy Host: analytics.diegonmarcos.com (with advanced config)
├── Proxy Host: mail.diegonmarcos.com (with advanced config)
└── Proxy Host: photos.diegonmarcos.com (with advanced config)

OCI VMs:
├── micro-1: Mailu (127.0.0.1:443), Matomo (127.0.0.1:8080)
└── flex-1: Immich (127.0.0.1:2283)
```
