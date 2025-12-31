# Mail Configuration Task Log - 2025-12-08

## Overview
Complete mail server setup on OCI VM (oci-f-micro_1 / 130.110.251.193) with Mailu replacing Stalwart.

---

## Infrastructure

| Component | Details |
|-----------|---------|
| **VM** | oci-f-micro_1 (130.110.251.193) |
| **Domain** | diegonmarcos.com |
| **Mail Server** | Mailu (Docker-based, 8 containers) |
| **Previous Server** | Stalwart (removed due to complex relay config) |

---

## Work Completed Today

### 1. Stalwart to Mailu Migration
- Removed Stalwart Mail Server (complex TOML/database config issues)
- Deployed Mailu with Docker Compose
- Configured lightweight setup (no antivirus, rspamd for antispam)

### 2. OCI Email Delivery Relay Configuration
Oracle Cloud blocks outbound port 25, so all outbound mail routed through OCI Email Delivery.

**Critical Fix:** RELAYHOST format requires square brackets and port:
```
RELAYHOST=[smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
RELAYUSER=ocid1.user.oc1..aaaaaaaaadh3p7atydr4ga3yvr3noohaar4f5h62d7stidvzkzgmilyt4enq@ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq.lm.com
RELAYPASSWORD=.<zLnkRzJBv$2FiJaf-G
```

**Note:** Square brackets around hostname and `:587` port are REQUIRED for Postfix relay configuration.

### 3. OCI Security List Configuration
Added ingress rules for mail ports:
- Port 25 (SMTP Inbound)
- Port 465 (SMTPS - used for client submission)
- Port 587 (SMTP STARTTLS)
- Port 993 (IMAPS)

### 4. OCI Email Delivery Setup
- Created approved sender: me@diegonmarcos.com
- Generated new SMTP credentials via OCI CLI
- Credentials saved to: `/tmp/new_smtp_cred.json`

### 5. Thunderbird Client Configuration
Verified and updated Thunderbird prefs.js:
```
IMAP: mail.diegonmarcos.com:993 (SSL/TLS)
SMTP: mail.diegonmarcos.com:465 (SSL/TLS)
Username: me@diegonmarcos.com
```

### 6. Email Delivery Testing
Sent test emails to:
- diegonmarcos@outlook.com - Delivered (to spam)
- diegonmarcos@live.com - Delivered (to spam)
- diegonmarcos1@gmail.com - Delivered (to spam/junk)

All emails delivered successfully (Mailu logs show `status=sent (250 Ok)`), but going to spam due to missing DKIM.

### 7. DKIM Configuration (COMPLETED)
Generated DKIM keys on server:
```bash
/opt/mailu/dkim/diegonmarcos.com.dkim.key  # Private key
/opt/mailu/dkim/diegonmarcos.com.dkim.pub  # Public key
```

**DNS Record Added to Cloudflare:**
- Name: `dkim._domainkey`
- Type: TXT
- Value: `v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmWJtaKXcpc/IizfCWA3/0P7AZwHVFsDUBwNLcI2h9cB5PcjM6INJBvKLKKrXxwoTGUuyezz8mKR6/3qWQw3tI52ulsbe8xkR3UkxhVVxrYbQrvd7jZW4JUMYiJFsyTWReucOrCieyjTWSwM7Rv03w5wL8M7BqPxt1E5B7UYGGJK7sHns8CrRTN9VAfb/YJSUl0LhxPglyuThnRmUW7bvVWe3EPG8zbt1xYrW8ea8Kd4SSS0X1yEI56g0YaLq/StSF1LAHzivfNey+KEvZ36YNkns8sPQw+7D6tCwpRwWJ7TJeRgYMzIQCpZqqHcx2HntBZsq9IslLRtvQXQzXvyoCQIDAQAB`

### 8. Cloudflare Worker for Inbound Email (COMPLETED)
Deployed email-forwarder worker to forward inbound emails to Gmail:
- Worker: `email-forwarder`
- Version: `c2546c42-17e0-44fb-9719-65397448a965`
- Route: `me@diegonmarcos.com` → Worker → `diegonmarcos@gmail.com`
- Config file: `/home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-f-micro_1/2.app/mail-app/cloudflare-worker/email-forwarder.js`

### 9. Email Testing (COMPLETED)
Outbound email tests successful:
- diegonmarcos1@gmail.com - Delivered ✓
- diegonmarcos@live.com - Delivered ✓
- diegonmarcos@outlook.com - Delivered ✓

All emails sent via Mailu → OCI Email Delivery relay (`status=sent (250 Ok)`)

---

## Current Status

### Working
- [x] Mailu containers running (8 containers healthy)
- [x] IMAP access (port 993)
- [x] SMTP submission (port 465 SMTPS)
- [x] OCI Email Delivery relay
- [x] Webmail (https://mail.diegonmarcos.com/webmail)
- [x] Admin panel (https://mail.diegonmarcos.com/admin)
- [x] Cloudflare Email Routing configured
- [x] Let's Encrypt TLS certificates

### Completed
- [x] DKIM DNS record added to Cloudflare
- [x] Cloudflare Worker deployed (forwards to Gmail)

---

## Credentials

### Mailu Admin
- URL: https://mail.diegonmarcos.com/admin
- Username: admin@diegonmarcos.com
- Password: 8HkSfq6mCW

### Email Account
- Email: me@diegonmarcos.com
- Password: ogeid1A!

### OCI SMTP Relay
- Host: smtp.email.eu-marseille-1.oci.oraclecloud.com:587
- Username: (see RELAYUSER above)
- Password: .<zLnkRzJBv$2FiJaf-G

---

## Architecture

### Inbound Mail Flow
```
Internet → Cloudflare (port 25) → Email Routing → Gmail (PRIMARY)
                                                → Mailu (ARCHIVE via Worker - planned)
```

### Outbound Mail Flow
```
Client → Mailu (port 465/SMTPS) → Postfix → OCI Email Delivery Relay → Internet
                                            [smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
```

---

## Configuration Files

| File | Location |
|------|----------|
| Mailu config | `/opt/mailu/mailu.env` |
| Docker Compose | `/opt/mailu/docker-compose.yml` |
| DKIM keys | `/opt/mailu/dkim/` |
| Thunderbird prefs | `~/.thunderbird/y1h3sth0.default/prefs.js` |

---

## Key Learnings

1. **Stalwart complexity**: Relay config split between TOML and database made troubleshooting difficult. Mailu's env-based config is simpler.

2. **Postfix RELAYHOST format**: Square brackets `[hostname]:port` are REQUIRED when specifying a port.

3. **OCI blocks port 25 outbound**: All outbound mail must go through OCI Email Delivery on port 587.

4. **Port 587 TLS issues**: Mailu port 587 had STARTTLS issues; using port 465 (implicit TLS/SMTPS) works reliably.

5. **Spam folder delivery**: Emails without DKIM go to spam. Gmail and Microsoft both flagged test emails as junk.

---

## SSH Access
```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193

# Check services
cd /opt/mailu && sudo docker-compose ps

# View logs
cd /opt/mailu && sudo docker-compose logs -f
```

---

## Status: COMPLETE

All mail server configuration tasks completed successfully:
- Mailu mail server running with DKIM signing
- Outbound mail via OCI Email Delivery relay
- Inbound mail via Cloudflare Email Routing to Gmail
- Landing page updated at https://mymail.diegonmarcos.com
