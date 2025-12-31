# NPM Migration - Old to New (GCloud)

**Date:** 2025-12-05
**From:** Oracle Services Server (129.151.228.66)
**To:** GCloud Arch-1 (34.55.55.234)

---

## Proxy Configurations to Recreate

### 1. n8n.diegonmarcos.com

**Domain Names:** n8n.diegonmarcos.com
**Scheme:** http
**Forward Hostname/IP:** 84.235.234.87
**Forward Port:** 5678
**Access List:** None
**Block Common Exploits:** ✓
**Websockets Support:** ✓
**SSL:** Let's Encrypt (expires 2026-02-25)
**Force SSL:** ☐
**HTTP/2 Support:** ☐
**HSTS Enabled:** ☐

---

## Manual Migration Steps

### Step 1: Access New NPM
1. Open browser: http://34.55.55.234:81
2. Login with: admin@example.com / changeme
3. **CHANGE PASSWORD IMMEDIATELY** to: Cu$sB^mFIAIIMhNBOGE%z6xH

### Step 2: Create Proxy Host

1. Click "Proxy Hosts" → "Add Proxy Host"
2. **Details Tab:**
   - Domain Names: `n8n.diegonmarcos.com`
   - Scheme: `http`
   - Forward Hostname/IP: `84.235.234.87`
   - Forward Port: `5678`
   - Cache Assets: ☐
   - Block Common Exploits: ✓
   - Websockets Support: ✓

3. **SSL Tab:**
   - SSL Certificate: Request a New SSL Certificate
   - Force SSL: ☐ (enable after cert is issued)
   - HTTP/2 Support: ☐
   - HSTS Enabled: ☐
   - Email: me@diegonmarcos.com
   - Agree to Terms: ✓

4. Click "Save"

### Step 3: Update DNS (Cloudflare)

**Before migration:**
- n8n.diegonmarcos.com → 129.151.228.66

**After migration:**
- n8n.diegonmarcos.com → 34.55.55.234

**Steps:**
1. Login to Cloudflare
2. Navigate to diegonmarcos.com DNS settings
3. Update A record for `n8n` subdomain
4. Change IP from 129.151.228.66 to 34.55.55.234
5. Keep Proxy status enabled (orange cloud)

### Step 4: Test

1. Wait for DNS propagation (1-5 minutes with Cloudflare)
2. Visit https://n8n.diegonmarcos.com
3. Verify n8n loads correctly
4. Check SSL certificate is valid

### Step 5: Clean Up Old NPM

**On Oracle Services Server (129.151.228.66):**
```bash
ssh -i ~/.ssh/id_rsa ubuntu@129.151.228.66

# Remove old NPM Docker volumes
docker volume rm npm_data npm_letsencrypt nginx-proxy-manager_npm_data nginx-proxy-manager_npm_letsencrypt

# Verify removal
docker volume ls | grep npm
```

---

## Future Proxy Hosts to Add

Based on Architecture v2, these services will need proxy hosts:

| Domain | Forward To | Port | Service |
|--------|-----------|------|---------|
| analytics.diegonmarcos.com | 129.151.228.66 | 8080 | Matomo Analytics |
| mail.diegonmarcos.com | 130.110.251.193 | TBD | Mail App |
| sync.diegonmarcos.com | 84.235.234.87 | 8384 | Syncthing |
| git.diegonmarcos.com | 84.235.234.87 | 3000 | Gitea |
| cloud.diegonmarcos.com | 84.235.234.87 | 5000 | Cloud Dashboard |

---

## Troubleshooting

### Issue: NPM container won't start
- Check logs: `gcloud compute ssh arch-1 --zone=us-central1-a --command="sudo docker logs npm"`
- Verify volumes: `sudo docker volume ls | grep npm`
- Restart: `cd ~/npm && sudo docker-compose restart`

### Issue: SSL certificate fails
- Ensure port 80 is accessible from internet
- Check Let's Encrypt rate limits
- Verify domain DNS is pointing to new NPM IP
- Email must be valid: me@diegonmarcos.com

### Issue: Proxy returns 502 Bad Gateway
- Verify backend service is running
- Check forward IP is correct
- Ensure port is accessible from NPM server
- Test: `curl http://84.235.234.87:5678` (should return n8n page)

---

## Verification Checklist

- [ ] NPM accessible at http://34.55.55.234:81
- [ ] Changed default password
- [ ] n8n proxy host created
- [ ] SSL certificate requested and valid
- [ ] DNS updated in Cloudflare
- [ ] https://n8n.diegonmarcos.com works
- [ ] Old NPM volumes removed from 129.151.228.66

---

## Notes

- The old NPM database showed only **1 proxy host** configured (n8n.diegonmarcos.com)
- Automatic database migration failed due to SELinux/permission issues on Fedora
- Manual recreation via UI is simpler and more reliable
- All SSL certificates will be fresh (Let's Encrypt auto-renews every 90 days)
