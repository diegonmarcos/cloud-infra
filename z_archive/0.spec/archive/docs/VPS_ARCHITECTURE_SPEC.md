# VPS Architecture Specification v2.0

Complete infrastructure documentation for secure, isolated multi-service VPS hosting.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Network Architecture](#2-network-architecture)
3. [Port Configuration](#3-port-configuration)
4. [Docker Network Isolation](#4-docker-network-isolation)
5. [Service Zones](#5-service-zones)
6. [Database Strategy](#6-database-strategy)
7. [Volume Mount Isolation](#7-volume-mount-isolation)
8. [Security Layers](#8-security-layers)
9. [Implementation Guide](#9-implementation-guide)
10. [Maintenance & Operations](#10-maintenance--operations)

---

## 1. Overview

### 1.1 Architecture Philosophy

**"Blast Radius Containment"** - Assume any public-facing service can be compromised. Design the infrastructure so that a breach in one service cannot spread to others.

### 1.2 Infrastructure Summary

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Cloud Provider** | Oracle Cloud (Always Free) | VPS Hosting |
| **Server** | ARM64 Ampere A1 | Compute |
| **OS** | Ubuntu 24.04 LTS | Host Operating System |
| **Containerization** | Docker + Compose | Service Isolation |
| **Reverse Proxy** | NGINX (Host) | Traffic Routing & SSL |
| **Firewall** | UFW + iptables | Network Security |

### 1.3 Resource Allocation

```
VPS Specifications:
├── CPU: 4 OCPUs (ARM64)
├── RAM: 24 GB
├── Boot Volume: 47 GB (/)
├── Block Volume 1: 50 GB (/mnt/public)
├── Block Volume 2: 50 GB (/mnt/private) [LUKS]
└── Block Volume 3: 50 GB (/mnt/mail) [LUKS]
```

---

## 2. Network Architecture

### 2.1 Traffic Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         INTERNET                                 │
│    HTTP(80) │ HTTPS(443) │ SSH(22) │ SMTP(25,587) │ IMAP(993)   │
└──────┬──────┴─────┬──────┴────┬────┴──────┬───────┴──────┬──────┘
       │            │           │           │              │
       ▼            ▼           ▼           ▼              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    UFW FIREWALL (Default: DROP)                  │
│   ✓ 22/tcp   ✓ 80/tcp   ✓ 443/tcp   ✓ 25/tcp   ✓ 587/tcp       │
│   ✓ 993/tcp  ✗ 8080     ✗ 3306      ✗ 5432     ✗ 27017         │
└──────┬──────────────┬─────────┬─────────────┬───────────────────┘
       │              │         │             │
       │              ▼         │             ▼
       │    ┌─────────────────┐ │   ┌─────────────────┐
       │    │  NGINX PROXY    │ │   │   MAIL SERVER   │
       │    │  (Host Level)   │ │   │   (Docker)      │
       │    │  Listen: 80,443 │ │   │   Listen: 25,   │
       │    └────────┬────────┘ │   │   587, 993      │
       │             │          │   └─────────────────┘
       │             ▼          │
       │    ┌─────────────────────────────────────┐
       │    │         DOCKER ENVIRONMENT          │
       │    │  ┌──────────┐  ┌──────────┐        │
       │    │  │ PUBLIC   │  │ PRIVATE  │        │
       │    │  │ NETWORK  │  │ NETWORK  │        │
       │    │  │ :8080    │  │ :8082    │        │
       │    │  │ :8081    │  │ internal │        │
       │    │  └──────────┘  └──────────┘        │
       │    └─────────────────────────────────────┘
       │
       ▼
┌─────────────────┐
│   HOST OS       │
│   (SSH Direct)  │
│   Ubuntu 24.04  │
└─────────────────┘
```

### 2.2 Key Design Decisions

1. **NGINX on Host (not Docker)**
   - SSL termination at host level
   - Direct access to Let's Encrypt
   - Survives container restarts

2. **Localhost Binding**
   - All containers bind to `127.0.0.1:port`
   - Prevents Docker UFW bypass vulnerability
   - Internet cannot reach containers directly

3. **SSH Direct Path**
   - SSH bypasses NGINX and Docker
   - Direct access to host OS
   - Emergency access even if containers fail

---

## 3. Port Configuration

### 3.1 External Ports (Internet-Facing)

| Port | Protocol | Service | Handler |
|------|----------|---------|---------|
| 22 | TCP | SSH | Host sshd |
| 80 | TCP | HTTP | Host NGINX (redirect) |
| 443 | TCP | HTTPS | Host NGINX (proxy) |
| 25 | TCP | SMTP | Docker mailserver |
| 587 | TCP | SMTP Submission | Docker mailserver |
| 993 | TCP | IMAPS | Docker mailserver |

### 3.2 Internal Ports (Localhost Only)

| Port | Service | Container | Network |
|------|---------|-----------|---------|
| 127.0.0.1:8080 | Matomo | matomo-app | public_net |
| 127.0.0.1:8081 | Static Web | web-server | public_net |
| 127.0.0.1:8082 | NextCloud | nextcloud-app | private_net |
| 127.0.0.1:8025 | Mail Web UI | mailserver | mail_net |
| internal:3306 | MariaDB | matomo-db | public_net |
| internal:5432 | PostgreSQL | nextcloud-db | private_net |
| internal:6379 | Redis | redis | private_net |

### 3.3 UFW Configuration

```bash
# Reset to defaults
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow specific ports
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP redirect'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw allow 25/tcp comment 'SMTP'
sudo ufw allow 587/tcp comment 'SMTP Submission'
sudo ufw allow 993/tcp comment 'IMAPS'

# Enable firewall
sudo ufw enable
sudo ufw status verbose
```

---

## 4. Docker Network Isolation

### 4.1 Network Topology

```yaml
networks:
  # Public services - internet accessible via NGINX
  public_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24

  # Private services - requires authentication
  private_net:
    driver: bridge
    internal: true  # No external access
    ipam:
      config:
        - subnet: 172.21.0.0/24

  # Mail services - isolated email stack
  mail_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.22.0.0/24

  # Database bridge - backup agent only
  db_bridge:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.23.0.0/24
```

### 4.2 Network Membership Matrix

| Container | public_net | private_net | mail_net | db_bridge |
|-----------|:----------:|:-----------:|:--------:|:---------:|
| web-server | ✓ | | | |
| matomo-app | ✓ | | | |
| matomo-db | ✓ | | | ✓ |
| nextcloud-app | | ✓ | | |
| nextcloud-db | | ✓ | | ✓ |
| redis | | ✓ | | |
| mailserver | | | ✓ | |
| mail-db | | | ✓ | ✓ |
| backup-agent | | | | ✓ |

### 4.3 Isolation Verification

```bash
# From matomo-app, verify cannot reach private network
docker exec matomo-app ping -c 1 172.21.0.2  # Should fail

# From nextcloud-app, verify cannot reach public network
docker exec nextcloud-app ping -c 1 172.20.0.2  # Should fail

# Verify internal network has no external access
docker exec nextcloud-db curl -s http://google.com  # Should fail
```

---

## 5. Service Zones

### 5.1 Public Zone (Internet Accessible)

**Purpose**: Services that need to be accessible from the internet without authentication.

| Service | Container | Port | Technology |
|---------|-----------|------|------------|
| Static Website | web-server | 8081 | nginx:alpine |
| Matomo Analytics | matomo-app | 8080 | matomo:fpm-alpine |
| Matomo Database | matomo-db | 3306 | mariadb:11.4 |

**Security Considerations**:
- Read-only filesystem for static content
- Rate limiting on all endpoints
- WAF rules in NGINX
- Regular security updates

### 5.2 Private Zone (Authentication Required)

**Purpose**: Personal services requiring login before access.

| Service | Container | Port | Technology |
|---------|-----------|------|------------|
| NextCloud | nextcloud-app | 8082 | nextcloud:fpm-alpine |
| NextCloud DB | nextcloud-db | 5432 | postgres:16-alpine |
| Redis Cache | redis | 6379 | redis:7-alpine |

**Security Considerations**:
- 2FA enforcement
- IP whitelist option
- Session timeout
- Encrypted storage

### 5.3 Mail Zone (Email Services)

**Purpose**: Self-hosted email infrastructure.

| Service | Container | Ports | Technology |
|---------|-----------|-------|------------|
| Mail Server | mailserver | 25,587,993 | docker-mailserver |
| Mail Database | mail-db | internal | SQLite |
| Mailboxes | (volume) | - | Maildir++ format |

**Security Considerations**:
- DKIM signing
- SPF records
- DMARC policy
- Fail2Ban integration
- TLS enforcement

---

## 6. Database Strategy

### 6.1 SQL vs NoSQL Decision Matrix

| Use Case | Type | Database | Reason |
|----------|------|----------|--------|
| Analytics (Matomo) | SQL | MariaDB | Complex queries, time-series |
| User Files (NextCloud) | SQL | PostgreSQL | Metadata, relations |
| Mail Accounts | SQL | SQLite | Simple, lightweight |
| Session Cache | NoSQL | Redis | Fast, ephemeral |
| Search Index | NoSQL | Redis | Key-value lookups |
| Email Storage | Files | Maildir | Standard format |

### 6.2 Database Isolation Rules

```
┌─────────────────────────────────────────────────────────────┐
│                    RULE: ONE DB PER SERVICE                  │
│                                                              │
│  ✗ WRONG: Single MariaDB for Matomo + NextCloud             │
│  ✓ RIGHT: Separate MariaDB (Matomo) + PostgreSQL (NC)       │
│                                                              │
│  Reason: Prevents privilege escalation between services     │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 Database Container Configuration

**MariaDB (Matomo)**:
```yaml
matomo-db:
  image: mariadb:11.4
  container_name: matomo-db
  networks:
    - public_net
    - db_bridge
  volumes:
    - /mnt/public/matomo-db:/var/lib/mysql
  environment:
    MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
    MARIADB_DATABASE: matomo
    MARIADB_USER: matomo
    MARIADB_PASSWORD_FILE: /run/secrets/db_password
  restart: unless-stopped
```

**PostgreSQL (NextCloud)**:
```yaml
nextcloud-db:
  image: postgres:16-alpine
  container_name: nextcloud-db
  networks:
    - private_net
    - db_bridge
  volumes:
    - /mnt/private/nextcloud-db:/var/lib/postgresql/data
  environment:
    POSTGRES_DB: nextcloud
    POSTGRES_USER: nextcloud
    POSTGRES_PASSWORD_FILE: /run/secrets/nc_db_password
  restart: unless-stopped
```

---

## 7. Volume Mount Isolation

### 7.1 Storage Partitions

```
Host Filesystem:
├── / (Boot Volume - 47GB)
│   ├── /etc/nginx/          # NGINX configs
│   ├── /opt/docker/         # Docker compose files
│   └── /home/ubuntu/        # User home
│
├── /mnt/public (Block Volume 1 - 50GB)
│   ├── matomo-db/           # MariaDB data
│   ├── matomo-files/        # Matomo uploads
│   └── web-static/          # Static website files
│
├── /mnt/private (Block Volume 2 - 50GB) [LUKS ENCRYPTED]
│   ├── nextcloud-db/        # PostgreSQL data
│   ├── nextcloud-files/     # User files
│   └── redis-data/          # Persistent cache
│
└── /mnt/mail (Block Volume 3 - 50GB) [LUKS ENCRYPTED]
    ├── mailboxes/           # Maildir storage
    ├── mail-config/         # Server configuration
    └── dkim-keys/           # DKIM signing keys
```

### 7.2 Mount Configuration

```yaml
services:
  # PUBLIC ZONE - uses /mnt/public
  web-server:
    volumes:
      - /mnt/public/web-static:/usr/share/nginx/html:ro  # READ-ONLY!

  matomo-app:
    volumes:
      - /mnt/public/matomo-files:/var/www/html

  matomo-db:
    volumes:
      - /mnt/public/matomo-db:/var/lib/mysql

  # PRIVATE ZONE - uses /mnt/private (encrypted)
  nextcloud-app:
    volumes:
      - /mnt/private/nextcloud-files:/var/www/html

  nextcloud-db:
    volumes:
      - /mnt/private/nextcloud-db:/var/lib/postgresql/data

  # MAIL ZONE - uses /mnt/mail (encrypted)
  mailserver:
    volumes:
      - /mnt/mail/mailboxes:/var/mail
      - /mnt/mail/mail-config:/tmp/docker-mailserver
```

### 7.3 LUKS Encryption Setup

```bash
# Create encrypted partition
sudo cryptsetup luksFormat /dev/sdb1
sudo cryptsetup open /dev/sdb1 private_crypt

# Format and mount
sudo mkfs.ext4 /dev/mapper/private_crypt
sudo mount /dev/mapper/private_crypt /mnt/private

# Auto-unlock at boot (with keyfile)
sudo dd if=/dev/urandom of=/root/.luks-keyfile bs=4096 count=1
sudo chmod 400 /root/.luks-keyfile
sudo cryptsetup luksAddKey /dev/sdb1 /root/.luks-keyfile

# /etc/crypttab
private_crypt /dev/sdb1 /root/.luks-keyfile luks
```

### 7.4 Isolation Verification

```bash
# Verify container cannot access other mounts
docker exec matomo-app ls /mnt/private  # Should fail (not mounted)
docker exec nextcloud-app ls /mnt/public  # Should fail (not mounted)

# Verify read-only mount
docker exec web-server touch /usr/share/nginx/html/test  # Should fail
```

---

## 8. Security Layers

### 8.1 Defense in Depth Model

```
Layer 1: Network Edge
├── Oracle Cloud Security Lists
├── UFW Firewall (host level)
└── Fail2Ban (brute force protection)

Layer 2: Traffic Routing
├── NGINX TLS termination
├── HTTP → HTTPS redirect
├── Rate limiting
└── Security headers

Layer 3: Application Isolation
├── Docker networks (no cross-talk)
├── Container user namespaces
├── Read-only filesystems
└── Resource limits (CPU, memory)

Layer 4: Data Protection
├── Separate volumes per service
├── LUKS encryption at rest
├── Database per service
└── Backup encryption
```

### 8.2 Security Hardening Checklist

**SSH Hardening**:
```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers ubuntu
```

**NGINX Security Headers**:
```nginx
# /etc/nginx/conf.d/security.conf
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

**Docker Hardening**:
```yaml
# docker-compose.yml security options
services:
  web-server:
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
```

### 8.3 Monitoring & Alerting

```bash
# Install monitoring stack
docker compose -f monitoring.yml up -d

# Components:
# - Prometheus: Metrics collection
# - Grafana: Visualization
# - Alertmanager: Alert routing
# - Node Exporter: Host metrics
# - cAdvisor: Container metrics
```

---

## 9. Implementation Guide

### 9.1 Phase 1: Base Infrastructure (Day 1)

```bash
# 1. Initial server setup
sudo apt update && sudo apt upgrade -y
sudo apt install -y docker.io docker-compose-v2 nginx certbot python3-certbot-nginx

# 2. Configure firewall
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# 3. Setup Docker
sudo usermod -aG docker ubuntu
sudo systemctl enable docker

# 4. Create directory structure
sudo mkdir -p /opt/docker/{public,private,mail}
sudo mkdir -p /mnt/{public,private,mail}
```

### 9.2 Phase 2: Public Services (Day 2)

```bash
# 1. Deploy Matomo (already done)
cd /opt/docker/public
docker compose up -d matomo-app matomo-db

# 2. Deploy static web server
docker compose up -d web-server

# 3. Configure NGINX
sudo nano /etc/nginx/sites-available/diegonmarcos.com
sudo ln -s /etc/nginx/sites-available/diegonmarcos.com /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 4. SSL certificates
sudo certbot --nginx -d diegonmarcos.com -d www.diegonmarcos.com
```

### 9.3 Phase 3: Private Services (Day 3-4)

```bash
# 1. Setup encrypted storage
sudo cryptsetup luksFormat /dev/sdb1
sudo cryptsetup open /dev/sdb1 private_crypt
sudo mkfs.ext4 /dev/mapper/private_crypt
sudo mount /dev/mapper/private_crypt /mnt/private

# 2. Deploy NextCloud
cd /opt/docker/private
docker compose up -d nextcloud-app nextcloud-db redis

# 3. Configure NGINX with auth
sudo nano /etc/nginx/sites-available/cloud.diegonmarcos.com
sudo certbot --nginx -d cloud.diegonmarcos.com
```

### 9.4 Phase 4: Mail Services (Day 5-6)

```bash
# 1. Setup mail encryption
sudo cryptsetup luksFormat /dev/sdc1
sudo cryptsetup open /dev/sdc1 mail_crypt
sudo mkfs.ext4 /dev/mapper/mail_crypt
sudo mount /dev/mapper/mail_crypt /mnt/mail

# 2. Open mail ports
sudo ufw allow 25/tcp
sudo ufw allow 587/tcp
sudo ufw allow 993/tcp

# 3. Deploy mail server
cd /opt/docker/mail
docker compose up -d mailserver

# 4. Configure DNS records (external)
# - MX record: mail.diegonmarcos.com
# - SPF: v=spf1 mx -all
# - DKIM: (generated key)
# - DMARC: v=DMARC1; p=quarantine
```

### 9.5 Phase 5: Hardening (Day 7)

```bash
# 1. Install Fail2Ban
sudo apt install -y fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo nano /etc/fail2ban/jail.local  # Configure jails
sudo systemctl enable fail2ban

# 2. Setup automated backups
cat > /opt/docker/backup.sh << 'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d)
# Backup databases
docker exec matomo-db mysqldump -u root matomo | gzip > /backup/matomo-$DATE.sql.gz
docker exec nextcloud-db pg_dump -U nextcloud | gzip > /backup/nextcloud-$DATE.sql.gz
# Encrypt and upload
gpg --encrypt --recipient backup@example.com /backup/*.gz
rclone copy /backup/*.gpg remote:backups/
EOF
chmod +x /opt/docker/backup.sh
crontab -e  # Add: 0 3 * * * /opt/docker/backup.sh

# 3. Enable automatic updates
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

---

## 10. Maintenance & Operations

### 10.1 Daily Operations

```bash
# Check service health
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# View logs
docker logs --tail 100 matomo-app
docker logs --tail 100 -f mailserver

# Check disk usage
df -h /mnt/*
docker system df
```

### 10.2 Weekly Operations

```bash
# Update containers
docker compose pull
docker compose up -d

# Clean old images
docker image prune -a --filter "until=168h"

# Verify backups
ls -la /backup/
rclone ls remote:backups/

# Security scan
docker scout cves matomo-app
```

### 10.3 Monthly Operations

```bash
# OS updates
sudo apt update && sudo apt upgrade -y

# SSL certificate check
sudo certbot certificates

# Review firewall rules
sudo ufw status verbose

# Audit Docker networks
docker network ls
docker network inspect public_net
```

### 10.4 Incident Response

**If container compromised**:
```bash
# 1. Isolate container
docker network disconnect public_net compromised-container
docker stop compromised-container

# 2. Preserve evidence
docker commit compromised-container evidence:$(date +%s)
docker logs compromised-container > /tmp/incident-logs.txt

# 3. Restore from backup
docker compose down compromised-service
rm -rf /mnt/public/compromised-data/*
# Restore from backup...
docker compose up -d compromised-service

# 4. Post-incident
# - Review logs
# - Update passwords
# - Patch vulnerabilities
# - Update monitoring
```

---

## Appendix A: Complete docker-compose.yml

See: [`/opt/docker/docker-compose.yml`](../vps_oracle/docker-compose.yml)

## Appendix B: NGINX Configurations

See: [`/opt/docker/nginx/`](../vps_oracle/nginx-proxy/)

## Appendix C: Related Documentation

- [Architecture Diagram (Interactive HTML)](./arch_diagram_v2.html)
- [Matomo Complete Spec](../vps_oracle/matomo/MATOMO_COMPLETE_SPEC.md)
- [Web Hosting Spec](../vps_oracle/web-hosting/README.md)
- [Mail Server Spec](../vps_oracle/mail-server/README.md)

---

**Document Version**: 2.0
**Last Updated**: 2025-11-26
**Author**: Infrastructure Team
**Status**: Active
