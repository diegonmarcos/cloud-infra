# Task: Vaultwarden Self-Hosted Password Manager

**Created:** 2025-12-08
**Agent:** Opus (Claude Code)
**Status:** READY TO DEPLOY

---

## Overview

**Migration:** Browser/Bitwarden (vault.bitwarden.eu) → Self-hosted Vaultwarden

### Current State
- **Source:** Bitwarden EU Cloud (vault.bitwarden.eu)
- **Data:** vault.json (1,127 passwords, 15 folders, 30 TOTP)
- **Clients:** Bitwarden browser extension, mobile apps

### Target State
- **Server:** Vaultwarden on oci-p-flex_1
- **Domain:** vault.diegonmarcos.com
- **Proxy:** NPM on gcp-f-micro_1 (34.55.55.234)
- **Auth:** Authelia 2FA protection

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        BITWARDEN CLIENTS                             │
│  (Browser Extension, Mobile Apps, Desktop, CLI)                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     vault.diegonmarcos.com                           │
│                         DNS → 34.55.55.234                           │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    NPM (gcp-f-micro_1)                               │
│              34.55.55.234:443 → 84.235.234.87:8081                   │
│                      + Authelia 2FA                                  │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                 VAULTWARDEN (oci-p-flex_1)                           │
│                     84.235.234.87:8081                               │
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │  Web Vault   │  │  WebSocket   │  │    SQLite    │               │
│  │   :8081      │  │    :3012     │  │   /data/db   │               │
│  └──────────────┘  └──────────────┘  └──────────────┘               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Resource Usage

| Resource | Min | Max |
|----------|-----|-----|
| RAM | 64 MB | 128 MB |
| Storage | 100 MB | 500 MB |
| Bandwidth | 100 MB/mo | 500 MB/mo |

**VM:** oci-p-flex_1 (8 GB RAM, 100 GB storage) - plenty of headroom

---

## Deployment Files

```
vps_oracle/vm-oci-p-flex_1/2.app/vault-app/
├── docker-compose.yml    # Main deployment config
├── .env.example          # Environment template
└── .env                  # Actual secrets (create manually)
```

---

## Configuration

### docker-compose.yml Settings

| Setting | Value | Notes |
|---------|-------|-------|
| Image | vaultwarden/server:latest | Official image |
| Port (Web) | 8081:80 | Avoids conflict with other services |
| Port (WS) | 3012:3012 | WebSocket for live sync |
| Domain | vault.diegonmarcos.com | HTTPS via NPM |
| Database | SQLite | /data/db.sqlite3 |
| Signups | Disabled | Security - invite only |
| Email | Gmail SMTP | For invites/recovery |

### Environment Variables

| Variable | Description | Source |
|----------|-------------|--------|
| ADMIN_TOKEN | Admin panel access | Generate new |
| SMTP_USERNAME | Gmail account | LOCAL_KEYS |
| SMTP_PASSWORD | Gmail app password | LOCAL_KEYS |

---

## NPM Proxy Configuration

### Proxy Host Settings

| Field | Value |
|-------|-------|
| Domain | vault.diegonmarcos.com |
| Forward Hostname | 84.235.234.87 |
| Forward Port | 8081 |
| Scheme | http |
| SSL | Let's Encrypt |
| Force SSL | Yes |
| HTTP/2 | Yes |
| WebSocket Support | Yes |

### Custom Nginx Config (Advanced)

```nginx
# WebSocket support for live sync
location /notifications/hub {
    proxy_pass http://84.235.234.87:3012;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}

location /notifications/hub/negotiate {
    proxy_pass http://84.235.234.87:8081;
}
```

### Authelia Protection (Optional)

Add to NPM Advanced config if using Authelia:
```nginx
include /data/nginx/proxy-confs/authelia-*.conf;
```

---

## DNS Configuration

Add to Cloudflare:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | vault | 34.55.55.234 | Proxied |

---

## Migration Workflow

### Phase 1: Deploy Server

```bash
# 1. SSH to oci-p-flex_1
ssh -i ~/.ssh/id_rsa ubuntu@84.235.234.87

# 2. Navigate to app directory
cd ~/2.app/vault-app

# 3. Create .env file
cp .env.example .env
nano .env  # Set ADMIN_TOKEN

# 4. Generate admin token
openssl rand -base64 48

# 5. Deploy
docker compose up -d

# 6. Verify
docker ps | grep vault
curl http://localhost:8081/alive
```

### Phase 2: Configure NPM

1. Login to NPM: http://34.55.55.234:81
2. Add Proxy Host:
   - Domain: vault.diegonmarcos.com
   - Forward: 84.235.234.87:8081
   - SSL: Request Let's Encrypt
   - Enable WebSocket Support

### Phase 3: DNS

1. Login to Cloudflare
2. Add A record: vault → 34.55.55.234

### Phase 4: Create Account

1. Access https://vault.diegonmarcos.com
2. Create master account (me@diegonmarcos.com)
3. Access admin panel: https://vault.diegonmarcos.com/admin
4. Disable admin token after setup (for security)

### Phase 5: Import Data

```bash
# On local machine

# 1. Export from vault.json
cd /home/diego/Documents/Git/LOCAL_KEYS
python build.py bitwarden
# Output: exports/bitwarden_import.json

# 2. Import to Vaultwarden
# Option A: Web UI
#   - Login to https://vault.diegonmarcos.com
#   - Settings → Import Data → Bitwarden (json)
#   - Upload bitwarden_import.json

# Option B: CLI
bw config server https://vault.diegonmarcos.com
bw login me@diegonmarcos.com
bw unlock
bw import bitwarden_json exports/bitwarden_import.json
bw sync
```

### Phase 6: Update Clients

| Client | Action |
|--------|--------|
| Browser Extension | Settings → Server URL → https://vault.diegonmarcos.com |
| Mobile App | Settings → Self-hosted → https://vault.diegonmarcos.com |
| Desktop App | Settings → Self-hosted → https://vault.diegonmarcos.com |
| CLI | `bw config server https://vault.diegonmarcos.com` |

---

## Security Considerations

### Must Do
- [ ] Generate strong ADMIN_TOKEN (openssl rand -base64 48)
- [ ] Disable ADMIN_TOKEN after initial setup
- [ ] Enable Authelia 2FA for web access
- [ ] Use strong master password
- [ ] Enable 2FA on Vaultwarden account

### Recommended
- [ ] Regular backups of /data/db.sqlite3
- [ ] Monitor container logs for suspicious activity
- [ ] Keep image updated (docker compose pull && docker compose up -d)

---

## Backup Strategy

### Automated Backup (via n8n)

Create n8n workflow:
1. Trigger: Daily at 3 AM
2. SSH to oci-p-flex_1
3. Copy /var/lib/docker/volumes/vaultwarden_data/_data/
4. Encrypt with GPG
5. Upload to Oracle Object Storage

### Manual Backup

```bash
# On oci-p-flex_1
docker exec vault-app sqlite3 /data/db.sqlite3 ".backup '/data/backup.sqlite3'"
docker cp vault-app:/data/backup.sqlite3 ./vaultwarden-backup-$(date +%Y%m%d).sqlite3
```

---

## Troubleshooting

### Container won't start
```bash
docker logs vault-app
```

### Can't access web vault
```bash
# Check if running
docker ps | grep vault

# Check port binding
ss -tlnp | grep 8081

# Check firewall
sudo iptables -L -n | grep 8081
```

### WebSocket not working
- Ensure NPM has "WebSocket Support" enabled
- Check custom nginx config for /notifications/hub

### Email not sending
- Verify Gmail app password in .env
- Check SMTP settings in container logs

---

## Update Reference

### cloud_dash.json

Service already exists (lines 473-502), update status:
- `status`: "dev" → "on" (after deployment)

### TASKS_OVERVIEW.md

Add new task entry for Task_Vaultwarden

---

## Checklist

### Deployment
- [ ] Create .env on server
- [ ] Deploy docker-compose
- [ ] Verify container running
- [ ] Add NPM proxy host
- [ ] Configure SSL
- [ ] Add DNS record
- [ ] Test web access

### Migration
- [ ] Export from vault.json
- [ ] Import to Vaultwarden
- [ ] Verify all passwords imported
- [ ] Update browser extension
- [ ] Update mobile app
- [ ] Test autofill

### Security
- [ ] Disable ADMIN_TOKEN
- [ ] Enable 2FA
- [ ] Configure Authelia
- [ ] Set up backups

---

**Status:** Ready to deploy
**Next Action:** SSH to oci-p-flex_1 and run docker compose up -d
