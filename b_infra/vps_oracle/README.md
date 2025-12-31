# Oracle VPS Infrastructure

Self-hosted services on Oracle Cloud Always Free tier VPS.

**Server**: 130.110.251.193 (EU-Marseille-1)
**OS**: Ubuntu 24.04 LTS
**Resources**: 2 vCPUs, 1GB RAM, 50GB storage

---

## 📖 Complete Documentation

**Main Specification**: [`MATOMO_COMPLETE_SPEC.md`](./MATOMO_COMPLETE_SPEC.md)

Comprehensive documentation for Matomo analytics including:
- Current operational status
- Anti-blocker proxy setup
- Performance optimizations
- GeoIP geolocation
- Management procedures
- Troubleshooting guide

---

## 📂 Infrastructure Layout

```
vps_oracle/
├── README.md                       # This file
├── MATOMO_COMPLETE_SPEC.md         # Complete Matomo documentation
│
├── matomo/                         # ✅ Analytics Service (Active)
│   ├── scripts/                    # Management scripts
│   └── README.md                   # Quick reference
│
├── mariadb/                        # ✅ Database Service (Active)
│   └── README.md                   # Database management
│
├── nginx-proxy/                    # ✅ Reverse Proxy (Active)
│   └── README.md                   # Proxy configuration
│
├── ubuntu-os/                      # 🖥️ OS Configuration
│   └── README.md                   # System config files & procedures
│
├── sync/                           # ⏳ Data Sync (Planned)
│   └── README.md                   # Desktop/Mobile/Garmin sync
│
├── firewall/                       # 🛡️ Security (Active)
│   └── README.md                   # Firewall rules & config
│
├── mail-server/                    # ⏳ Email Server (Planned)
│   └── README.md                   # Self-hosted email
│
└── web-hosting/                    # ⏳ Web Hosting (Planned)
    └── README.md                   # Static/dynamic site hosting
```

---

## 🎯 Services Overview

### ✅ Active Services

| Service | Status | URL | Purpose |
|---------|--------|-----|---------|
| **Matomo Analytics** | ✅ Running | https://analytics.diegonmarcos.com | Privacy-friendly analytics |
| **MariaDB** | ✅ Running | Internal only | Database backend |
| **Nginx Proxy Manager** | ✅ Running | http://130.110.251.193:81 | Reverse proxy + SSL |
| **Firewall** | ✅ Active | Oracle Security Lists | Network security |
| **Ubuntu OS** | ✅ Running | SSH access | Base operating system |

### ⏳ Planned Services

| Service | Priority | Est. Resources | Target Domain |
|---------|----------|----------------|---------------|
| **Sync Service** | High | ~300 MB RAM | sync.diegonmarcos.com |
| **Web Hosting** | High | ~100 MB/site | *.diegonmarcos.com |
| **Mail Server** | Medium | ~400 MB RAM | mail.diegonmarcos.com |

---

## 🚀 Quick Access

### SSH to Server

```bash
ssh -i ~/.ssh/matomo_key ubuntu@130.110.251.193
```

### Management Scripts

```bash
cd matomo/scripts
./matomo-login.sh              # Quick SSH
./matomo-manage.sh status      # Check services
./matomo-manage.sh logs        # View logs
```

### Service URLs

| Service | URL |
|---------|-----|
| **Matomo Dashboard** | https://analytics.diegonmarcos.com |
| **Nginx Admin** | http://130.110.251.193:81 |
| **Direct Matomo** | http://130.110.251.193:8080 |

---

## 📊 Current Resource Usage

| Component | RAM | CPU | Disk |
|-----------|-----|-----|------|
| **Matomo** | ~300 MB | 0.3 vCPU | ~500 MB |
| **MariaDB** | ~200 MB | 0.2 vCPU | ~200 MB |
| **Nginx Proxy** | ~50 MB | 0.1 vCPU | ~100 MB |
| **System** | ~100 MB | 0.1 vCPU | ~2 GB |
| **Total Used** | **~650 MB** | **0.7 vCPU** | **~3 GB** |
| **Available** | **~350 MB** | **1.3 vCPU** | **~47 GB** |

**Capacity**: Can handle 1-2 more lightweight services or 3-5 static sites.

---

## 🛠️ Per-Service Quick Links

### Active Services

**Matomo Analytics**:
- 📖 Docs: [`matomo/README.md`](./matomo/README.md)
- 🔧 Scripts: [`matomo/scripts/`](./matomo/scripts/)
- 📋 Complete Spec: [`MATOMO_COMPLETE_SPEC.md`](./MATOMO_COMPLETE_SPEC.md)

**MariaDB Database**:
- 📖 Docs: [`mariadb/README.md`](./mariadb/README.md)
- 🔧 Management: Backup, restore, shell access

**Nginx Proxy Manager**:
- 📖 Docs: [`nginx-proxy/README.md`](./nginx-proxy/README.md)
- 🌐 Admin UI: http://130.110.251.193:81

**Firewall**:
- 📖 Docs: [`firewall/README.md`](./firewall/README.md)
- 🛡️ Config: Oracle Security Lists + iptables

**Ubuntu OS**:
- 📖 Docs: [`ubuntu-os/README.md`](./ubuntu-os/README.md)
- ⚙️ Config: System files, cron, services

### Planned Services

**Sync Service** (Desktop/Mobile/Garmin):
- 📖 Plan: [`sync/README.md`](./sync/README.md)
- 🎯 Status: Planning - Technology evaluation

**Web Hosting** (Static/Dynamic sites):
- 📖 Plan: [`web-hosting/README.md`](./web-hosting/README.md)
- 🎯 Status: Planning - Next priority

**Mail Server** (Self-hosted email):
- 📖 Plan: [`mail-server/README.md`](./mail-server/README.md)
- 🎯 Status: Planning - Resource evaluation needed

---

## 🔧 Common Operations

### Check All Services

```bash
ssh ubuntu@130.110.251.193 "cd ~/matomo && sudo docker compose ps"
```

### View Logs

```bash
# All services
sudo docker compose logs -f

# Specific service
sudo docker compose logs -f matomo-app
sudo docker compose logs -f matomo-db
sudo docker compose logs -f nginx-proxy
```

### Restart Services

```bash
cd ~/matomo
sudo docker compose restart
```

### System Status

```bash
# Resource usage
htop

# Disk space
df -h

# Docker usage
sudo docker system df
```

---

## 📈 Matomo Analytics Features

### Current Configuration

- ✅ **Tracking**: ~95% coverage (anti-blocker proxy)
- ✅ **GeoIP**: 95% accuracy (DBIP City Lite)
- ✅ **Performance**: Reports load <1 second (cron archiving)
- ✅ **Security**: Force HTTPS, self-hosted
- ✅ **Privacy**: GDPR compliant, no third-party data sharing

### Anti-Blocker Proxy

Bypasses ad-blockers like Brave Shields:
- `collect.php` - Main disguised endpoint
- `api.php` - Backup endpoint
- `track.php` - Alternative endpoint

### Tag Manager

- Container ID: `62tfw1ai`
- Version: v6 "Proxy Tracking"
- Endpoint: `collect.php`

---

## 🔐 Security Status

### Active Protections

✅ **Network Level**:
- Oracle Cloud Security Lists (firewall)
- SSH key-based authentication only
- No password authentication

✅ **Application Level**:
- SSL/TLS via Let's Encrypt (auto-renewal)
- Force HTTPS enabled
- Rate limiting (Nginx)
- Common exploit blocking

✅ **Container Level**:
- Docker internal networking (isolation)
- No direct database access from internet
- Limited container resources

### Planned Improvements

⏳ **Fail2ban**: SSH brute-force protection
⏳ **IP Whitelisting**: Restrict SSH to known IPs
⏳ **Port Hardening**: Close unnecessary exposed ports

---

## 💾 Backup Strategy

### Current Backups

**Matomo**: Daily via cron (recommended)
```bash
docker exec matomo-db mysqldump -u matomo -p matomo > backup.sql
```

**System Config**: Manual (documented in ubuntu-os/)

### Planned Automated Backups

- Daily database backups (7-day retention)
- Weekly full system backups
- Off-site backup to cloud storage
- Automated restore testing

---

## 📚 Documentation Index

| Document | Purpose |
|----------|---------|
| [`README.md`](./README.md) | This file - overview & navigation |
| [`MATOMO_COMPLETE_SPEC.md`](./MATOMO_COMPLETE_SPEC.md) | Complete Matomo documentation |
| [`matomo/README.md`](./matomo/README.md) | Matomo quick reference |
| [`mariadb/README.md`](./mariadb/README.md) | Database management |
| [`nginx-proxy/README.md`](./nginx-proxy/README.md) | Proxy configuration |
| [`ubuntu-os/README.md`](./ubuntu-os/README.md) | OS configuration |
| [`firewall/README.md`](./firewall/README.md) | Security & firewall |
| [`sync/README.md`](./sync/README.md) | Sync service (planned) |
| [`web-hosting/README.md`](./web-hosting/README.md) | Web hosting (planned) |
| [`mail-server/README.md`](./mail-server/README.md) | Email server (planned) |

---

## 🎯 Next Steps

### Immediate Tasks

1. ✅ Matomo fully operational
2. ✅ Documentation consolidated
3. ⏳ Set up automated backups
4. ⏳ Install fail2ban

### Short-term (Next Month)

1. ⏳ Deploy web hosting service
2. ⏳ Evaluate sync solutions (Nextcloud vs Syncthing)
3. ⏳ Create backup automation script
4. ⏳ Implement IP whitelisting for SSH

### Long-term (Next Quarter)

1. ⏳ Deploy sync service
2. ⏳ Evaluate mail server feasibility
3. ⏳ Consider VPS upgrade if needed
4. ⏳ Implement monitoring/alerting

---

## 🆘 Emergency Contacts & Resources

### Oracle Cloud

- **Console**: https://cloud.oracle.com/
- **Support**: https://cloud.oracle.com/support
- **Documentation**: https://docs.oracle.com/iaas/

### Service Documentation

- **Matomo**: https://matomo.org/docs/
- **Nginx Proxy Manager**: https://nginxproxymanager.com/guide/
- **MariaDB**: https://mariadb.org/documentation/
- **Docker**: https://docs.docker.com/

### Emergency Access

If SSH fails, use Oracle Cloud Console → Instance → Console Connection

---

## 📊 Version History

| Date | Version | Changes |
|------|---------|---------|
| 2025-11-25 | 1.0 | Initial consolidated structure |
| 2025-11-25 | 1.1 | Added service folders & specs |

---

**Last Updated**: 2025-11-25
**Maintainer**: Diego Nepomuceno Marcos
**Server**: Oracle Cloud Always Free (EU-Marseille-1)
