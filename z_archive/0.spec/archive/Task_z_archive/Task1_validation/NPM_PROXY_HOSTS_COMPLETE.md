# NPM Proxy Hosts Configuration - COMPLETE ✅

**Date:** 2025-12-05
**Location:** GCloud Arch-1 (34.55.55.234)
**NPM Admin:** http://34.55.55.234:81

---

## ✅ All Proxy Hosts Configured

### 1. n8n.diegonmarcos.com
- **Forward To:** 84.235.234.87:5678 (Oracle Dev Server)
- **Service:** n8n Automation
- **Status:** ✅ ENABLED
- **Websockets:** Enabled
- **Block Exploits:** Enabled
- **SSL:** Not yet configured

### 2. sync.diegonmarcos.com
- **Forward To:** 84.235.234.87:8384 (Oracle Dev Server)
- **Service:** Syncthing File Sync
- **Status:** ✅ ENABLED
- **Websockets:** Enabled
- **Block Exploits:** Enabled
- **SSL:** Not yet configured

### 3. git.diegonmarcos.com
- **Forward To:** 84.235.234.87:3000 (Oracle Dev Server)
- **Service:** Gitea Git Server
- **Status:** ✅ ENABLED
- **Websockets:** Enabled
- **Block Exploits:** Enabled
- **SSL:** Not yet configured

### 4. analytics.diegonmarcos.com
- **Forward To:** 129.151.228.66:8080 (Oracle Services Server)
- **Service:** Matomo Analytics
- **Status:** ✅ ENABLED
- **Websockets:** Enabled
- **Block Exploits:** Enabled
- **SSL:** Not yet configured

### 5. cloud.diegonmarcos.com
- **Forward To:** 84.235.234.87:5000 (Oracle Dev Server)
- **Service:** Cloud Dashboard
- **Status:** ✅ ENABLED
- **Websockets:** Enabled
- **Block Exploits:** Enabled
- **SSL:** Not yet configured

---

## 🔧 Technical Implementation

### Method: Direct Database Modification
- Downloaded NPM database from GCloud
- Fixed n8n port from 56789 → 5678
- Added 4 new proxy hosts via SQL INSERT
- Uploaded modified database back to GCloud
- Restarted NPM container

### Database Modifications
```sql
-- Fix n8n port
UPDATE proxy_host
SET forward_port = 5678, modified_on = '2025-12-05 ...'
WHERE id = 1;

-- Insert new proxy hosts
INSERT INTO proxy_host (id, domain_names, forward_host, forward_port, ...)
VALUES
  (2, '["sync.diegonmarcos.com"]', '84.235.234.87', 8384, ...),
  (3, '["git.diegonmarcos.com"]', '84.235.234.87', 3000, ...),
  (4, '["analytics.diegonmarcos.com"]', '129.151.228.66', 8080, ...),
  (5, '["cloud.diegonmarcos.com"]', '84.235.234.87', 5000, ...);
```

---

## ⚠️ Next Steps Required

### 1. Fix DNS Records in Squarespace
**Current Issue:** DNS not pointing to new NPM IP

**Required Changes:**
| Domain | Current IP | Should Be | Status |
|--------|-----------|-----------|--------|
| n8n.diegonmarcos.com | 129.151.228.66 | 34.55.55.234 | ❌ WRONG |
| analytics.diegonmarcos.com | 130.110.251.193 | 34.55.55.234 | ❌ WRONG |
| sync.diegonmarcos.com | 34.55.55.234 | 34.55.55.234 | ✅ CORRECT |
| git.diegonmarcos.com | ? | 34.55.55.234 | ❓ UNKNOWN |
| cloud.diegonmarcos.com | ? | 34.55.55.234 | ❓ UNKNOWN |

**Action Required:**
1. Login to Squarespace DNS management
2. Update/create A records for all domains to point to 34.55.55.234
3. Verify records are saved (not just cached in browser)
4. Wait 1-5 minutes for DNS propagation

### 2. Delete Obsolete Domain Forwarding
**Found:** oracle-services-server-1.diegonmarcos.com → 129.151.228.66:81

**Issue:** This forwards to the old NPM that was deleted

**Action Required:**
- Delete this forwarding rule from Squarespace

### 3. Configure SSL Certificates
**Once DNS propagates**, add Let's Encrypt SSL via NPM web UI:

1. Login: http://34.55.55.234:81
2. For each proxy host:
   - Edit → SSL tab
   - Request a New SSL Certificate
   - Email: me@diegonmarcos.com
   - Agree to Let's Encrypt Terms
   - Enable "Force SSL"
   - Save

---

## 🧪 Testing Commands

### Test NPM is responding (Direct IP)
```bash
curl -I http://34.55.55.234
```

### Test proxy hosts (Direct IP with Host header)
```bash
curl -H "Host: n8n.diegonmarcos.com" http://34.55.55.234
curl -H "Host: sync.diegonmarcos.com" http://34.55.55.234
curl -H "Host: git.diegonmarcos.com" http://34.55.55.234
curl -H "Host: analytics.diegonmarcos.com" http://34.55.55.234
curl -H "Host: cloud.diegonmarcos.com" http://34.55.55.234
```

### Test DNS resolution
```bash
dig n8n.diegonmarcos.com +short
dig analytics.diegonmarcos.com +short
dig sync.diegonmarcos.com +short
dig git.diegonmarcos.com +short
dig cloud.diegonmarcos.com +short
```

### Test HTTPS (After DNS + SSL configured)
```bash
curl -I https://n8n.diegonmarcos.com
curl -I https://sync.diegonmarcos.com
curl -I https://git.diegonmarcos.com
curl -I https://analytics.diegonmarcos.com
curl -I https://cloud.diegonmarcos.com
```

---

## 📊 Summary

- ✅ **5/5 Proxy Hosts Configured** in NPM
- ✅ **n8n Port Fixed** (56789 → 5678)
- ✅ **NPM Restarted** successfully
- ✅ **Database Verified** locally
- ❌ **DNS Not Updated** (2/5 domains wrong)
- ❌ **SSL Not Configured** (waiting for DNS)

---

## 🚀 Architecture Overview

```
User → DNS (Squarespace)
  ↓
GCloud Arch-1 (34.55.55.234)
  ↓
Nginx Proxy Manager (NPM)
  ↓
  ├── n8n.diegonmarcos.com → 84.235.234.87:5678 (Oracle Dev)
  ├── sync.diegonmarcos.com → 84.235.234.87:8384 (Oracle Dev)
  ├── git.diegonmarcos.com → 84.235.234.87:3000 (Oracle Dev)
  ├── analytics.diegonmarcos.com → 129.151.228.66:8080 (Oracle Services)
  └── cloud.diegonmarcos.com → 84.235.234.87:5000 (Oracle Dev)
```

---

**Configuration Completed By:** Claude Code (Sonnet 4.5)
**Remaining Work:** DNS updates + SSL configuration (manual via Squarespace + NPM web UI)
