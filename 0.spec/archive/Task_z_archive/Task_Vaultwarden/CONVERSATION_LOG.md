# Vaultwarden Implementation - Conversation Log

**Date:** 2025-12-08
**Agent:** Claude Opus 4.5
**Session:** Implementation Planning

---

## User Request

```
lets implement Passwords | from here: Browser/Bitwarden? to: Vaultwarden (self-hosted);
add spec files and all log of this conversation sinde here:
/home/diego/Documents/Git/back-System/cloud/0.spec/Task_Vaultwarden
```

---

## Context Analysis

### Explored Files
1. `/home/diego/Documents/Git/back-System/cloud/` - Infrastructure structure
2. `vps_oracle/vm-oci-p-flex_1/2.app/git-app/docker-compose.yml` - Deployment pattern
3. `vps_oracle/vm-oci-f-micro_2/2.app/npm-app/docker-compose.yml` - NPM config
4. `0.spec/TASKS_OVERVIEW.md` - Task organization
5. `0.spec/cloud_dash.json` - Infrastructure definition
6. `/home/diego/Documents/Git/LOCAL_KEYS/SPEC.md` - Credentials structure

### Key Findings

1. **Vaultwarden already planned** in cloud_dash.json:
   - Service: vault, vault-app (lines 473-502)
   - VM: oci-p-flex_1 (84.235.234.87)
   - Domain: vault.diegonmarcos.com
   - Proxy via: gcp-f-micro_1 (34.55.55.234)
   - Internal port: 80
   - Status: dev

2. **Current password setup**:
   - Source of truth: vault.json (1,127 passwords)
   - Export tool: build.py → bitwarden_import.json
   - Cloud sync: Bitwarden EU (vault.bitwarden.eu)
   - Browser: Bitwarden extension
   - TOTP: Aegis + Garmin

3. **Infrastructure pattern**:
   - Docker-compose deployments
   - NPM reverse proxy with Let's Encrypt SSL
   - Authelia 2FA protection
   - dev_network Docker network

---

## Files Created

### 1. docker-compose.yml
**Path:** `vps_oracle/vm-oci-p-flex_1/2.app/vault-app/docker-compose.yml`

**Configuration:**
- Image: vaultwarden/server:latest
- Ports: 8081:80 (web), 3012:3012 (websocket)
- Network: dev_network
- Volume: vaultwarden_data:/data
- Memory: 64-128 MB limit
- Features:
  - Signups disabled (security)
  - WebSocket enabled (live sync)
  - Gmail SMTP for email
  - SQLite database

### 2. .env.example
**Path:** `vps_oracle/vm-oci-p-flex_1/2.app/vault-app/.env.example`

Template for environment variables:
- ADMIN_TOKEN (generate with openssl)
- SMTP credentials (from LOCAL_KEYS)

### 3. SPEC_VAULTWARDEN.md
**Path:** `0.spec/Task_Vaultwarden/SPEC_VAULTWARDEN.md`

Complete specification including:
- Architecture diagram
- Resource usage
- Deployment steps
- NPM configuration
- DNS configuration
- Migration workflow (6 phases)
- Security considerations
- Backup strategy
- Troubleshooting guide
- Deployment checklist

---

## Architecture Decision

```
Browser → vault.diegonmarcos.com → NPM (34.55.55.234:443)
                                       ↓
                                   Authelia 2FA
                                       ↓
                             Vaultwarden (84.235.234.87:8081)
```

**Rationale:**
- Use existing NPM for SSL termination
- Authelia provides additional 2FA layer
- Wake-on-demand VM is fine (passwords cached locally)
- SQLite sufficient for single-user

---

## Migration Plan Summary

1. **Deploy** - docker compose up on oci-p-flex_1
2. **Configure NPM** - Add proxy host with WebSocket support
3. **DNS** - Add vault.diegonmarcos.com A record
4. **Create Account** - Master user + disable admin token
5. **Import Data** - build.py bitwarden → web import
6. **Update Clients** - Point all apps to vault.diegonmarcos.com

---

## Next Steps for User

1. SSH to oci-p-flex_1
2. Create .env from .env.example
3. Run `docker compose up -d`
4. Configure NPM proxy host
5. Add Cloudflare DNS record
6. Import passwords

---

## Session Summary

- **Duration:** Single session
- **Files Created:** 4
- **Directories Created:** 2
- **Status:** Ready to deploy

The implementation is complete from a configuration perspective. All files are ready for deployment on the server.
