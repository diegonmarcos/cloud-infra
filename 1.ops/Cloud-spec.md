# Cloud Infrastructure Specification

> **Version**: 6.1.0 | **Updated**: 2025-12-23

## Source of Truth

| File | Path | Purpose |
|------|------|---------|
| **cloud_architecture.json** | `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_architecture.json` | Infrastructure state (VMs, services, networks) |
| **cloud_control.json** | `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_control.json` | Operational control (wake-on-demand, schedules) |

> **IMPORTANT**: Any changes to this spec document MUST be reflected in the JSON files above. The JSON files are the canonical source consumed by dashboards and automation.

---

## Table of Contents

### PART I: OVERVIEW
- 1. [Quick Reference](#1-quick-reference)
- 2. [Infrastructure Overview](#2-infrastructure-overview)

### PART II: INFRASTRUCTURE
- 3. [Virtual Machines](#3-virtual-machines)
- 4. [Services](#4-services)
- 5. [Network Architecture](#5-network-architecture)
- 6. [Docker Network Isolation](#6-docker-network-isolation)

### PART III: SECURITY
- 7. [Security Architecture](#7-security-architecture)

### PART IV: DATA
- 8. [Volume & Storage Strategy](#8-volume--storage-strategy)
- 9. [Database Strategy](#9-database-strategy)

### PART V: OPERATIONS
- 10. [SSH & Access Commands](#10-ssh--access-commands)
- 11. [Front-End Integration](#11-front-end-integration)
- 12. [Operations & Maintenance](#12-operations--maintenance)

### PART VI: REFERENCE & DASHBOARD
- 13. [Diagrams](#13-diagrams)
- 14. [Authentication & Admin API](#14-authentication--admin-api)
- 15. [Dashboard Architecture](#15-dashboard-architecture)
- 16. [Frontend Views Specification](#16-frontend-views-specification)

---

# PART I: OVERVIEW

## 1. Quick Reference

### Active Services
| Service ID | Display Name | URL | Status |
|------------|--------------|-----|--------|
| photoprism-app | Photo Gallery (with 2FA) | https://photos.diegonmarcos.com | on |
| matomo-app | Matomo Analytics | https://analytics.diegonmarcos.com | on |
| cloud-app | Cloud Dashboard | https://cloud.diegonmarcos.com | on |
| api | Cloud API | https://api.diegonmarcos.com | on |
| mailu | Mail Server | https://mail.diegonmarcos.com | on |
| calendar | Radicale Calendar | https://cal.diegonmarcos.com | on |
| ntfy | Push Notifications | https://rss.diegonmarcos.com | on |

### Proxy Admin Panel (SINGLE NPM)
| Server | URL |
|--------|-----|
| GCloud NPM (Central) | http://35.226.147.64:81 |

### Cloud Consoles
| Provider | URL |
|----------|-----|
| Oracle Cloud | https://cloud.oracle.com |
| Google Cloud | https://console.cloud.google.com |

### SSH Quick Commands
```bash
# Oracle Paid Flex 1 (Photoprism, Calendar, Cloud API) - Wake-on-Demand
ssh ubuntu@84.235.234.87

# Oracle Free Micro 1 (Mailu Mail)
ssh ubuntu@130.110.251.193

# Oracle Free Micro 2 (Matomo Analytics)
ssh ubuntu@129.151.228.66

# GCloud Free Micro 1 (NPM Central, Authelia, Flask API, ntfy)
gcloud compute ssh arch-1 --zone us-central1-a
```

---

## 2. Infrastructure Overview

```
+-------------------------------------------------------------------------+
|                        CLOUD INFRASTRUCTURE                              |
+-------------------------------------------------------------------------+
|                                                                          |
|  +-------------------------------------------------------------------+  |
|  |                    ORACLE CLOUD                                    |  |
|  |                                                                    |  |
|  |  +-------------------------+    +-------------------------+        |  |
|  |  |  oci-f-micro_1          |    |  oci-f-micro_2          |        |  |
|  |  |  130.110.251.193        |    |  129.151.228.66         |        |  |
|  |  |  WireGuard: 10.0.0.3    |    |  WireGuard: 10.0.0.4    |        |  |
|  |  |  VM.Standard.E2.1.Micro |    |  VM.Standard.E2.1.Micro |        |  |
|  |  |  1 OCPU | 1GB RAM       |    |  1 OCPU | 1GB RAM       |        |  |
|  |  |                         |    |                         |        |  |
|  |  |  Services:              |    |  Services:              |        |  |
|  |  |  - Mailu (Mail)         |    |  - Matomo Analytics     |        |  |
|  |  |                         |    |                         |        |  |
|  |  |  Status: ONLINE (Free)  |    |  Status: ONLINE (Free)  |        |  |
|  |  +-------------------------+    +-------------------------+        |  |
|  |                                                                    |  |
|  |  +-------------------------+                                       |  |
|  |  |  oci-p-flex_1           |    (VM.Standard.E4.Flex)              |  |
|  |  |  84.235.234.87          |    1 OCPU | 8GB RAM | 100GB           |  |
|  |  |  WireGuard: 10.0.0.2    |                                       |  |
|  |  |                         |                                       |  |
|  |  |  Services:              |    Status: WAKE-ON-DEMAND (Paid)      |  |
|  |  |  - Photoprism (Photos)  |                                       |  |
|  |  |  - Radicale (Calendar)  |                                       |  |
|  |  |  - Redis (Cache)        |                                       |  |
|  |  +-------------------------+                                       |  |
|  +-------------------------------------------------------------------+  |
|                                                                          |
|  +-------------------------------------------------------------------+  |
|  |                    GOOGLE CLOUD (Free Tier)                        |  |
|  |                                                                    |  |
|  |  +-------------------------+                                       |  |
|  |  |  gcp-f-micro_1          |    (e2-micro)                         |  |
|  |  |  35.226.147.64           |    0.25-2 vCPU | 1GB RAM              |  |
|  |  |  WireGuard: 10.0.0.1    |                                       |  |
|  |  |                         |                                       |  |
|  |  |  Services:              |                                       |  |
|  |  |  - NPM (Central Proxy)  |                                       |  |
|  |  |  - Authelia (2FA)       |                                       |  |
|  |  |  - Cloud API (Flask)    |                                       |  |
|  |  |  - ntfy (Push/RSS)      |                                       |  |
|  |  |                         |                                       |  |
|  |  |  Status: ONLINE (Free)  |                                       |  |
|  |  +-------------------------+                                       |  |
|  +-------------------------------------------------------------------+  |
|                                                                          |
+-------------------------------------------------------------------------+
```

---

# PART II: INFRASTRUCTURE

## 3. Virtual Machines

### 3.1 VM Categories

| Category | Description |
|----------|-------------|
| **Services** | General purpose VMs for web services and applications |

### 3.2 Active VMs

#### oci-f-micro_1 (Mail Server)
| Property | Value |
|----------|-------|
| **ID** | oci-f-micro_1 |
| **Provider** | Oracle Cloud |
| **IP** | 130.110.251.193 |
| **Type** | VM.Standard.E2.1.Micro |
| **Specs** | 1 OCPU (AMD), 1GB RAM, 47GB Boot |
| **OS** | Ubuntu 24.04 LTS |
| **Services** | Mailu Mail Suite |
| **Ports** | 22, 25, 587, 993, 8080 |
| **Availability** | 24/7 (Free) |
| **Status** | Active |

#### oci-f-micro_2 (Analytics)
| Property | Value |
|----------|-------|
| **ID** | oci-f-micro_2 |
| **Provider** | Oracle Cloud |
| **IP** | 129.151.228.66 |
| **Type** | VM.Standard.E2.1.Micro |
| **Specs** | 1 OCPU (AMD), 1GB RAM, 47GB Boot |
| **OS** | Ubuntu 24.04 LTS |
| **Services** | Matomo Analytics |
| **Ports** | 22, 80, 443, 8080, 3306 |
| **Availability** | 24/7 (Free) |
| **Status** | Active |

#### gcp-f-micro_1 (Central Proxy)
| Property | Value |
|----------|-------|
| **ID** | gcp-f-micro_1 |
| **Provider** | Google Cloud |
| **IP** | 35.226.147.64 |
| **Type** | e2-micro |
| **Specs** | 0.25-2 vCPU, 1GB RAM, 30GB |
| **OS** | Arch Linux (rolling) |
| **Services** | NPM (SINGLE CENTRAL), Authelia 2FA, Flask API |
| **Ports** | 22, 80, 443, 81, 9091, 6379 |
| **Availability** | 24/7 (Free) |
| **Status** | Active |

#### oci-p-flex_1 (Dev Server - Wake-on-Demand)
| Property | Value |
|----------|-------|
| **ID** | oci-p-flex_1 |
| **Provider** | Oracle Cloud |
| **IP** | 84.235.234.87 |
| **Type** | VM.Standard.E4.Flex |
| **Specs** | 1 OCPU (2 vCPU), 8GB RAM, 100GB |
| **OS** | Ubuntu 22.04 Minimal |
| **Services** | Photoprism, Radicale Calendar, Redis Cache |
| **Ports** | 22, 443, 5000, 6379, 2342, 5232 |
| **Availability** | Wake-on-Demand |
| **Cost** | ~$5.50/mo |
| **Status** | Active |

---

## 4. Services

### 4.1 Service Categories

| Category | Description |
|----------|-------------|
| **Infrastructure** | Core infrastructure services (proxy, API, auth) |
| **Productivity** | Productivity and communication tools |
| **Web** | Web analytics and monitoring |
| **Automation** | Workflow automation services |

### 4.2 Service Resource Requirements

| Status | Service ID | Category | RAM (Avg) | Storage (Avg) | Bandwidth (Avg) | Notes |
|--------|------------|----------|-----------|---------------|-----------------|-------|
| | **mail** | Productivity | | | | Mailu Email Suite (Cloudflare routing) |
| on | ↳ mailu (8 containers) | | 300-500 MB | 5-50 GB | 1-10 GB/mo | Full mail suite, Cloudflare Email Routing |
| on | ↳ mail-db (RocksDB) | | 8-32 MB | Variable | - | Embedded RocksDB |
| | **analytics** | Web | | | | Matomo Analytics platform |
| on | ↳ matomo-app | | 256-512 MB | 2-5 GB | 500 MB-2 GB/mo | PHP FPM Alpine |
| on | ↳ matomo-db | | 256-512 MB | 1-10 GB | - | MariaDB - grows with data |
| | **npm** | Infrastructure | | | | Central reverse proxy |
| on | ↳ npm-gcloud | | 128-256 MB | 100-500 MB | 5-20 GB/mo | SSL certs + configs |
| | **authelia** | Infrastructure | | | | 2FA authentication |
| on | ↳ authelia-app | | 32-64 MB | 50-100 MB | 100-500 MB/mo | TOTP + session management |
| | **photos** | Productivity | | | | Photoprism photo gallery |
| on | ↳ photoprism-app | | 1-2 GB | 10-50 GB | 5-20 GB/mo | Photo indexing + UI |
| on | ↳ photoprism-db | | 128-256 MB | 1-5 GB | - | MariaDB |
| | **calendar** | Productivity | | | | Radicale calendar |
| on | ↳ radicale-app | | 32-64 MB | 50-200 MB | 50-200 MB/mo | CalDAV/CardDAV |
| | **cloud** | Infrastructure | | | | Cloud Dashboard |
| on | ↳ cloud-app | | - | 5 MB | 50-200 MB/mo | Static HTML/CSS/JS |
| on | ↳ flask-app | | 64-128 MB | 50-100 MB | 100-500 MB/mo | Flask API Server |
| | **TOTAL** | | **~1.5-3 GB** | **~20-80 GB** | **~10-45 GB/mo** | All active services |


**VM Totals (Estimated)**:

| VM | Services | Total RAM (Est) | Total Storage (Est) | Bandwidth (Est) |
|----|----------|-----------------|---------------------|-----------------|
| oci-f-micro_1 | mailu | ~300-500 MB | ~5-50 GB | ~1-10 GB/mo |
| oci-f-micro_2 | matomo-app, matomo-db | ~500 MB - 1 GB | ~3-15 GB | ~500 MB-2 GB/mo |
| oci-p-flex_1 | photoprism, radicale, redis | ~1.2-2.5 GB | ~15-60 GB | ~5-25 GB/mo |
| gcp-f-micro_1 | npm, authelia, flask-app | ~200-450 MB | ~200 MB-700 MB | ~5-20 GB/mo |
| **TOTAL** | | **~2.5-5 GB** | **~120-230 GB** | **~23-105 GB/mo** |

---

### 4.3 Infrastructure Services

#### NPM (Web Server)
| Property | Value |
|----------|-------|
| **VM** | Oracle Web Server 1 |
| **Admin URL** | http://130.110.251.193:81 |
| **Technology** | jc21/nginx-proxy-manager |
| **Features** | SSL termination, Let's Encrypt, Access lists |
| **Status** | Active |

#### NPM (Services Server)
| Property | Value |
|----------|-------|
| **VM** | Oracle Services Server 1 |
| **Admin URL** | http://129.151.228.66:81 |
| **Technology** | jc21/nginx-proxy-manager |
| **Status** | Active |

#### Cloud Dashboard
| Property | Value |
|----------|-------|
| **Domain** | cloud.diegonmarcos.com |
| **Technology** | GitHub Pages (static) |
| **Status** | Active |

#### Cloud API
| Property | Value |
|----------|-------|
| **VM** | GCloud Arch Linux 1 (35.226.147.64) |
| **Domain** | api.diegonmarcos.com |
| **Internal Port** | 5000 |
| **Technology** | Python Flask (Docker container: `api`) |
| **Container** | api |
| **Image** | api:latest (python:3.11-slim + flask) |
| **Features** | VM/Service health checks, Wake-on-Demand API, Dashboard data |
| **Endpoints** | `/api/health`, `/api/vms`, `/api/services`, `/api/wake/*` |
| **Restart Policy** | unless-stopped |
| **Status** | Active |

### 4.4 Web Services

#### Matomo Analytics
| Property | Value |
|----------|-------|
| **VM** | Oracle Web Server 1 |
| **Domain** | analytics.diegonmarcos.com |
| **Internal Port** | 8080 |
| **Technology** | matomo:fpm-alpine + mariadb:11.4 |
| **Container** | matomo-app, matomo-db |
| **Features** | Anti-blocker proxy, Tag Manager, Custom events |
| **Status** | Active |

### 4.5 Productivity Services

#### Mail Server (Mailu)
| Property | Value |
|----------|-------|
| **VM** | oci-f-micro_1 (130.110.251.193) |
| **Login Page** | https://mail.diegonmarcos.com → diegonmarcos.github.io/mymail (Authelia SSO) |
| **Webmail URL** | https://mail.diegonmarcos.com/webmail (Roundcube via Authelia) |
| **Admin URL** | https://mail.diegonmarcos.com/admin |
| **IMAP Server** | imap.diegonmarcos.com:993 (SSL) |
| **SMTP Server** | smtp.diegonmarcos.com:465 (SSL) - Note: Port 587 blocked by Oracle Cloud |
| **Technology** | Mailu (8 containers: front, admin, imap, smtp, webmail, antispam, resolver, redis) |
| **Server Stack** | Mailu (Postfix SMTP + Dovecot IMAP + Rspamd Antispam) |
| **Webmail Client** | Roundcube (with calendar plugin for CalDAV integration) |
| **Auth** | Authelia SSO (proxy auth via NPM) + PROXY_AUTH_HEADER |
| **Ports** | 25 (SMTP relay), 465 (SMTPS client), 993 (IMAPS), 443 (HTTPS webmail) |
| **Features** | IMAP, SMTP, Webmail (Roundcube), Antispam (Rspamd), CalDAV (via Radicale) |
| **Email Routing** | Cloudflare Email Routing → Mailu:587 |
| **Status** | On |

**Mail Flow Architecture:**

Oracle Cloud blocks SMTP port 25 both inbound and outbound (anti-spam policy). The workaround uses relay services:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           INBOUND EMAIL                                  │
│                                                                          │
│   sender@gmail.com → me@diegonmarcos.com                                │
│                                                                          │
│   ┌──────────────┐      ┌──────────────────┐      ┌──────────────────┐  │
│   │   Internet   │ ──▶  │   Cloudflare MX  │ ──▶  │   Mailu:587      │  │
│   │   Port 25    │      │   (Email Worker) │      │   (Submission)   │  │
│   └──────────────┘      │   route1/2/3.mx  │      │   130.110.251.193│  │
│                         │   .cloudflare.net│      └──────────────────┘  │
│                         └──────────────────┘                             │
│                                                                          │
│   Cloudflare receives mail on port 25, forwards to Mailu on port 587    │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                          OUTBOUND EMAIL                                  │
│                                                                          │
│   me@diegonmarcos.com → recipient@gmail.com                             │
│                                                                          │
│   ┌──────────────────┐      ┌──────────────────┐      ┌──────────────┐  │
│   │   Mailu:25       │ ──▶  │   Oracle Email   │ ──▶  │   Internet   │  │
│   │   (Postfix SMTP) │      │   Delivery (OCI) │      │   Recipient  │  │
│   │   130.110.251.193│      │   (SMTP Relay)   │      │              │  │
│   └──────────────────┘      └──────────────────┘      └──────────────┘  │
│                                                                          │
│   Mailu relays through Oracle Email Delivery (authenticated relay)      │
└─────────────────────────────────────────────────────────────────────────┘
```

**Port Usage:**

| Direction | Port | Flow | Purpose |
|-----------|------|------|---------|
| **Inbound** | 25→587 | Internet → Cloudflare MX → Mailu | Receiving external mail |
| **Outbound** | 25→relay | Mailu → Oracle Email Delivery → Internet | Sending external mail |
| **IMAP** | 993 | Client ↔ Mailu (direct) | Reading mail (SSL) |
| **SMTPS** | 465 | Client → Mailu → relay | Sending from mail client (SSL) |
| **Webmail** | 443 | Browser → NPM → Authelia → Mailu | Web interface (SSO) |

**Note:** Port 587 (STARTTLS) is blocked by Oracle Cloud. Use port 465 (SSL) for email clients.

**DNS Records:**

```
MX Records (Inbound):
  22  route1.mx.cloudflare.net  (primary)
  85  route2.mx.cloudflare.net  (backup)
  97  route3.mx.cloudflare.net  (backup)

SPF Record (Outbound authorization):
  v=spf1 include:_spf.mx.cloudflare.net include:rp.oracleemaildelivery.com ~all
         ↑ Cloudflare inbound           ↑ Oracle relay outbound

DKIM: mail._domainkey.diegonmarcos.com (RSA 2048-bit)
```

#### Calendar & Contacts (Radicale)
| Property | Value |
|----------|-------|
| **VM** | oci-p-flex_1 (wake-on-demand) |
| **Domain** | cal.diegonmarcos.com |
| **Internal Port** | 5232 |
| **Technology** | Radicale (Python) |
| **Container** | tomsquest/docker-radicale |
| **Features** | CalDAV, CardDAV |
| **RAM** | ~30-50 MB |
| **Status** | Active |

**Clients:** Thunderbird, iOS Calendar, Android DAVx5

---

## 5. Network Architecture

### 5.1 Traffic Flow

```
+-------------------------------------------------------------------------+
|                              INTERNET                                    |
|    HTTP(80) | HTTPS(443) | SSH(22) | SMTP(25,587) | IMAP(993)           |
+------+------+------+------+----+----+------+-------+------+--------------+
       |            |           |           |              |
       v            v           v           v              v
+-------------------------------------------------------------------------+
|                    UFW FIREWALL (Default: DROP)                          |
|   OK: 22/tcp  OK: 80/tcp  OK: 443/tcp  OK: 25/tcp  OK: 587/tcp          |
|   OK: 993/tcp  BLOCKED: 8080  BLOCKED: 3306  BLOCKED: 5432              |
+------+----------------+----------+----------------+----------------------+
       |                |          |                |
       |                v          |                v
       |      +-----------------+  |      +-----------------+
       |      |  NGINX PROXY    |  |      |   MAIL SERVER   |
       |      |  (Host Level)   |  |      |   (Docker)      |
       |      |  Listen: 80,443 |  |      |   Listen: 25,   |
       |      +--------+--------+  |      |   587, 993      |
       |               |           |      +-----------------+
       |               v           |
       |      +--------------------------------------+
       |      |         DOCKER ENVIRONMENT          |
       |      |  +------------+  +------------+     |
       |      |  | PUBLIC     |  | PRIVATE    |     |
       |      |  | NETWORK    |  | NETWORK    |     |
       |      |  | :8080      |  | :8082      |     |
       |      |  | :8081      |  | internal   |     |
       |      |  +------------+  +------------+     |
       |      +--------------------------------------+
       |
       v
+-----------------+
|   HOST OS       |
|   (SSH Direct)  |
|   Ubuntu 24.04  |
+-----------------+
```

### 5.2 External Ports (Internet-Facing)

| Port | Protocol | Service | VM |
|------|----------|---------|-----|
| 22 | TCP | SSH | All |
| 80 | TCP | HTTP (redirect to HTTPS) | All |
| 443 | TCP | HTTPS | All |
| 81 | TCP | NPM Admin | gcp-f-micro_1 |

### 5.3 Internal Ports (localhost only, proxied via NPM)

| Port | Service | VM |
|------|---------|-----|
| 8080 | Matomo | oci-f-micro_2 |
| 3306 | MariaDB | oci-f-micro_2 |
| 9091 | Authelia | gcp-f-micro_1 |
| 6379 | Redis | gcp-f-micro_1, oci-p-flex_1 |
| 2342 | Photoprism | oci-p-flex_1 |
| 5232 | Radicale | oci-p-flex_1 |

### 5.4 Key Design Decisions

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

## 6. Docker Network Isolation

### 6.1 Network Topology

```yaml
networks:
  # Public services - internet accessible via NGINX
  public_net:
    driver: bridge
    subnet: 172.20.0.0/24
    purpose: Public services accessible via NGINX

  # Private services - requires authentication
  private_net:
    driver: bridge
    internal: true  # No external access
    subnet: 172.21.0.0/24
    purpose: Private services requiring authentication

  # Mail services - isolated email stack
  mail_net:
    driver: bridge
    subnet: 172.22.0.0/24
    purpose: Isolated email stack

  # Database bridge - backup agent only
  db_bridge:
    driver: bridge
    internal: true
    subnet: 172.23.0.0/24
    purpose: Database backup agent access
```

### 6.2 Network Membership Matrix

| Container | public_net | private_net | mail_net | db_bridge |
|-----------|:----------:|:-----------:|:--------:|:---------:|
| web-server | X | | | |
| matomo-app | X | | | |
| matomo-db | X | | | X |
| nextcloud-app | | X | | |
| nextcloud-db | | X | | X |
| redis | | X | | |
| mailserver | | | X | |
| mail-db | | | X | X |
| backup-agent | | | | X |

### 6.3 Isolation Verification

```bash
# From matomo-app, verify cannot reach private network
docker exec matomo-app ping -c 1 172.21.0.2  # Should fail

# From nextcloud-app, verify cannot reach public network
docker exec nextcloud-app ping -c 1 172.20.0.2  # Should fail

# Verify internal network has no external access
docker exec nextcloud-db curl -s http://google.com  # Should fail
```

---

# PART III: SECURITY

## 7. Security Architecture

### 7.1 Architecture Philosophy

**"Blast Radius Containment"** - Assume any public-facing service can be compromised. Design the infrastructure so that a breach in one service cannot spread to others.

### 7.2 Defense in Depth Model

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

### 7.3 UFW Configuration

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

### 7.4 SSH Hardening

```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers ubuntu
```

### 7.5 NGINX Security Headers

```nginx
# /etc/nginx/conf.d/security.conf
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

### 7.6 Docker Hardening

```yaml
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

### 7.7 Security Services Inventory

| Service | Type | Description | Location | Status |
|---------|------|-------------|----------|--------|
| **MyVault** | Password Manager | Bitwarden EU - Secure credential storage | vault.bitwarden.eu (SaaS) | ON |
| **Authelia** | 2FA Gateway | TOTP authentication for protected services (SMTP: Gmail) | GCP Micro 1 | ON |
| **OAuth2 Proxy** | Admin Auth | GitHub OAuth2 authentication proxy | GCP Micro 1 | ON |
| **NPM + SSL** | TLS Termination | Let's Encrypt certificates with auto-renewal | GCP Micro 1 | ON |
| **Docker Networks** | Network Isolation | Segmented: public_net, private_net, db_bridge | OCI Flex 1 | ON |
| **SSH Keys** | Access Control | Key-based auth for all VMs - no passwords | All VMs | ON |
| **Cloud Firewalls** | Network Security | OCI Security Lists + GCP Firewall Rules | OCI + GCP | ON |
| **Gmail SMTP Relay** | Email Notifications | App Password auth for Authelia notifications | Gmail (SaaS) | ON |
| **Sauron** | Malware Scanner | Rust YARA scanner with incremental scanning | oci-p-flex_1 | ON |
| **Collector** | Log Aggregator | journald + Sauron alerts → ntfy | oci-p-flex_1 | ON |

### 7.7.1 Security Monitoring Stack (Sauron + Collector)

**Overview**: Two-container security stack providing malware scanning and unified system alerting via ntfy.

| Component | Purpose | Image | Resource Limits |
|-----------|---------|-------|-----------------|
| **sauron** | YARA malware scanner | Rust binary on Debian slim | CPU: 25%, RAM: 256 MB |
| **collector** | Log aggregator + ntfy forwarder | Debian slim + curl | CPU: 5%, RAM: 32 MB |

**Deployed On**: `oci-p-flex_1` (84.235.234.87)

**Architecture**:
```
┌─────────────────────────────────────────────────────────────┐
│                    oci-p-flex_1 (8 GB RAM)                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                     SAURON                           │   │
│  │  ┌──────────────┐      ┌──────────────────────────┐ │   │
│  │  │ YARA Engine  │ ──── │ Rules (.yar files)       │ │   │
│  │  │ (Rust binary)│      │ - webshells.yar          │ │   │
│  │  └──────┬───────┘      │ - cryptominers.yar       │ │   │
│  │         │              │ - suspicious.yar         │ │   │
│  │         │              └──────────────────────────┘ │   │
│  │         │ incremental scan (only modified files)    │   │
│  │         ▼                                           │   │
│  │  /watch/etc + /watch/docker-volumes                 │   │
│  │         │                                           │   │
│  │         ▼                                           │   │
│  │  Docker logs (JSON alerts)                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                              │                              │
│  ┌───────────────────────────┼─────────────────────────┐   │
│  │                     COLLECTOR                        │   │
│  │                           │                          │   │
│  │  journald ──┬── SSH ──────┼──► ntfy/auth            │   │
│  │             ├── Docker ───┼──► ntfy/system          │   │
│  │             └── Critical ─┼──► ntfy/system          │   │
│  │                           │                          │   │
│  │  Sauron ─── Malware ──────┼──► ntfy/sauron          │   │
│  └───────────────────────────┼─────────────────────────┘   │
│                              │                              │
└──────────────────────────────┼──────────────────────────────┘
                               │ HTTPS
                               ▼
                https://rss.diegonmarcos.com (ntfy)
                               │
                               ▼
                      CloudFeed Dashboard
```

**Scan Mode: Incremental**
```
Startup:    Full scan of all files (baseline)
Hour 1:     Only files modified since startup (via find -newer)
Hour 2:     Only files modified since Hour 1
...
```

**ntfy Topics**:

| Topic | URL | Events |
|-------|-----|--------|
| `system` | `rss.diegonmarcos.com/system` | Docker crashes, critical errors |
| `auth` | `rss.diegonmarcos.com/auth` | SSH logins, failed attempts |
| `sauron` | `rss.diegonmarcos.com/sauron` | Malware detections |

**YARA Rules**:
```
yara-rules/custom/
├── webshells.yar     # PHP/JSP backdoors (eval, system, etc.)
├── cryptominers.yar  # XMRig, stratum+tcp patterns
└── suspicious.yar    # Reverse shells, credential theft, container escapes
```

**Docker Compose Configuration**:
```yaml
services:
  sauron:
    container_name: sauron
    build:
      context: .
      dockerfile: Dockerfile.sauron
    cpus: "0.25"
    mem_limit: 256m
    volumes:
      - /etc:/watch/etc:ro
      - /var/lib/docker/volumes:/watch/docker-volumes:ro
      - ./yara-rules:/etc/sauron/yara-rules:ro
      - ./entrypoint.sh:/entrypoint.sh:ro
    environment:
      - RULES_DIR=/etc/sauron/yara-rules/custom
      - WATCH_DIR=/watch
      - SCAN_INTERVAL=3600
      - WORKERS=1

  collector:
    container_name: collector
    build:
      context: ./collector
    network_mode: host
    cpus: "0.05"
    mem_limit: 32m
    volumes:
      - /var/log/journal:/var/log/journal:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - NTFY_URL=https://rss.diegonmarcos.com
      - VM_NAME=oci-flex
      - CHECK_INTERVAL=30
```

**Alert Format (Sauron)**:
```json
{
  "detections": [{
    "path": "/watch/home/user/backdoor.php",
    "detected": true,
    "tags": ["PHP_WebShell_Generic"]
  }]
}
```

**Alert Format (ntfy)**:
```
Title: Malware detected: oci-flex
Priority: urgent
Tags: biohazard, skull
Message: {"path":"/watch/...", "tags":["PHP_WebShell_Generic"]}
```

**Location**: `~/sauron` on oci-p-flex_1
**Spec Files**:
- `/home/diego/Documents/Git/back-System/cloud/a_solutions/back-security/anti-virus/sauron/SPEC.md`
- `/home/diego/Documents/Git/back-System/cloud/a_solutions/back-security/anti-virus/sauron/collector/SPEC.md`

### 7.8 Security Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                     │
│                                                                           │
│   ┌─────────────┐                              ┌─────────────────────┐   │
│   │    User     │──────────HTTPS──────────────▶│  Bitwarden EU       │   │
│   │   Browser   │                              │  (MyVault)          │   │
│   └──────┬──────┘                              └─────────────────────┘   │
│          │                                                                │
│          │ HTTPS (443)                                                    │
│          ▼                                                                │
│   ┌─────────────────────────────────────────┐                            │
│   │        GCP Free Micro 1 (35.226.147.64)  │                            │
│   │  ┌─────────────┐    ┌─────────────────┐ │                            │
│   │  │     NPM     │───▶│    Authelia     │ │                            │
│   │  │  SSL Proxy  │    │   2FA + TOTP    │ │                            │
│   │  └─────────────┘    └────────┬────────┘ │                            │
│   └──────────────────────────────┼──────────┘                            │
│                                  │ Authenticated                          │
│          ┌───────────────────────┼───────────────────────┐               │
│          ▼                       ▼                       ▼               │
│   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐       │
│   │ OCI Flex 1  │         │ OCI Micro 2 │         │ Other       │       │
│   │ (84.235...) │         │ (129.151..) │         │ Services    │       │
│   │             │         │             │         │             │       │
│   │ ┌─────────┐ │         │ ┌─────────┐ │         │             │       │
│   │ │public_  │ │         │ │ Matomo  │ │         │             │       │
│   │ │net      │ │         │ └─────────┘ │         │             │       │
│   │ ├─────────┤ │         └─────────────┘         └─────────────┘       │
│   │ │private_ │ │                                                        │
│   │ │net      │ │                                                        │
│   │ ├─────────┤ │                                                        │
│   │ │db_bridge│ │                                                        │
│   │ └─────────┘ │                                                        │
│   └─────────────┘                                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.9 Docker UFW Bypass Prevention

**The Problem**: By default, Docker modifies iptables directly, bypassing UFW rules. A container exposed with `-p 8080:80` becomes accessible from the internet even if UFW blocks port 8080.

**Solution 1: Bind to localhost only**
```yaml
# docker-compose.yml
services:
  photoprism:
    ports:
      - "127.0.0.1:2342:2342"  # Only accessible from localhost
    # NOT: "2342:2342"  # This exposes to internet!
```

**Solution 2: Disable Docker's iptables manipulation**
```json
// /etc/docker/daemon.json
{
  "iptables": false
}
```
> **Warning**: This requires manual network configuration for containers.

**Solution 3: Use Docker internal networks (Recommended)**
```yaml
# docker-compose.yml
networks:
  internal:
    internal: true  # No external access

services:
  app:
    networks:
      - internal
  db:
    networks:
      - internal
```

### 7.10 WireGuard VPN Mesh Network

All VMs are connected via WireGuard mesh network with GCP as the central hub. This enables secure inter-VM communication and prevents direct public IP access bypassing authentication.

**Network Topology**:
```
                           WireGuard Mesh Network (10.0.0.0/24)
                           ═══════════════════════════════════

                                  ┌─────────────────────┐
                                  │  GCP Hub (10.0.0.1) │
                                  │  35.226.147.64:51820 │
                                  │  NPM, Authelia, API │
                                  └──────────┬──────────┘
                                             │
              ┌──────────────────────────────┼──────────────────────────────┐
              │                              │                              │
              ▼                              ▼                              ▼
┌─────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
│  Oracle Dev         │      │  Oracle Web         │      │  Oracle Services    │
│  10.0.0.2           │      │  10.0.0.3           │      │  10.0.0.4           │
│  84.235.234.87      │      │  130.110.251.193    │      │  129.151.228.66     │
│  Photoprism,Cal     │      │  Mailu              │      │  Matomo             │
└─────────────────────┘      └─────────────────────┘      └─────────────────────┘

              ┌─────────────────────┐
              │  Local Machine      │
              │  10.0.0.5           │  (optional peer)
              │  diego-laptop       │
              └─────────────────────┘
```

**WireGuard IP Assignments**:
| Node | Public IP | WireGuard IP | Role |
|------|-----------|--------------|------|
| GCP Hub | 35.226.147.64 | 10.0.0.1 | Central Hub |
| Oracle Dev | 84.235.234.87 | 10.0.0.2 | Peer |
| Oracle Web | 130.110.251.193 | 10.0.0.3 | Peer |
| Oracle Services | 129.151.228.66 | 10.0.0.4 | Peer |
| Local Machine | dynamic | 10.0.0.5 | Optional Peer |

**Security Benefits**:
```
WITHOUT WireGuard (INSECURE):
User → 84.235.234.87:2342 → Photoprism directly (BYPASSES 2FA!) ✗

WITH WireGuard (SECURE):
User → photos.diegonmarcos.com → GCP:443 → NPM → Authelia 2FA ✓
                                             │
                                             ▼
                                    10.0.0.2:2342 (WireGuard only)
                                             │
                                             ▼
                                        Photoprism
```

**Configuration (GCP Hub)**:
```bash
# /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
PrivateKey = <GCP_PRIVATE_KEY>
ListenPort = 51820

[Peer]
# Oracle Dev
PublicKey = <ORACLE_DEV_PUBKEY>
AllowedIPs = 10.0.0.2/32
Endpoint = 84.235.234.87:51820
PersistentKeepalive = 25

[Peer]
# Oracle Web
PublicKey = <ORACLE_WEB_PUBKEY>
AllowedIPs = 10.0.0.3/32
Endpoint = 130.110.251.193:51820
PersistentKeepalive = 25

[Peer]
# Oracle Services
PublicKey = <ORACLE_SERVICES_PUBKEY>
AllowedIPs = 10.0.0.4/32
Endpoint = 129.151.228.66:51820
PersistentKeepalive = 25
```

**Local Machine VPN Manager**:
```bash
# Location: cloud/a_solutions/vpn/wireguard/vpn_manager.py

python vpn_manager.py status      # Check VPN status
python vpn_manager.py setup       # Generate keys and config
python vpn_manager.py add-peer    # Add this machine to GCP hub
python vpn_manager.py connect     # Connect to VPN
python vpn_manager.py disconnect  # Disconnect
```

**Bind Services to WireGuard Only**:
```yaml
services:
  photoprism:
    ports:
      - "10.0.0.2:2342:2342"  # Only accessible via WireGuard!
```

### 7.11 Authelia 2FA Integration

Authelia provides TOTP-based 2FA for services that don't have native authentication or need an additional security layer.

**Request Flow Diagram**:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            REQUEST FLOW                                      │
└─────────────────────────────────────────────────────────────────────────────┘

Browser: https://photos.diegonmarcos.com
         │
         ▼
┌─────────────────┐
│   CLOUDFLARE    │  DNS resolves to GCP IP (35.226.147.64)
│   (DNS + CDN)   │  Proxies request to origin
└────────┬────────┘
         │ Port 443 (HTTPS)
         ▼
┌─────────────────┐
│   GCP VM        │  35.226.147.64
│   (NPM Proxy)   │  Nginx Proxy Manager
└────────┬────────┘
         │
         │  auth_request /authelia-verify ──────────────┐
         │                                       │
         │                                       ▼
         │                            ┌─────────────────┐
         │                            │    AUTHELIA     │
         │                            │   (localhost)   │
         │                            │   Port 9091     │
         │                            └────────┬────────┘
         │                                     │
         │  ◄─── 401 Unauthorized ─────────────┘
         │       (no valid session)
         │
         ▼
┌─────────────────┐
│  REDIRECT 302   │  → https://auth.diegonmarcos.com/?rd=https://photos.diegonmarcos.com
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   USER LOGS IN  │  Username + Password + TOTP
│   (Authelia UI) │
└────────┬────────┘
         │
         │  Sets cookie: authelia_session (domain: diegonmarcos.com, path: /)
         │
         ▼
┌─────────────────┐
│  REDIRECT 302   │  → https://photos.diegonmarcos.com/photoprism (original URL)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   GCP VM        │  NPM checks auth_request again
│   (NPM Proxy)   │
└────────┬────────┘
         │
         │  auth_request /authelia-verify ──────────────┐
         │  (with cookie this time)              │
         │                                       ▼
         │                            ┌─────────────────┐
         │                            │    AUTHELIA     │
         │                            │  Validates      │
         │                            │  session cookie │
         │                            └────────┬────────┘
         │                                     │
         │  ◄─── 200 OK ───────────────────────┘
         │       (session valid, 2FA passed)
         │
         │  WireGuard Tunnel (10.0.0.1 → 10.0.0.2)
         ▼
┌─────────────────┐
│  ORACLE DEV VM  │  10.0.0.2:2342
│  (Photoprism)   │  Only accessible via WireGuard
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Photoprism UI  │  Auto-login via Lua module
│  (with 2FA)     │  (credentials injected after Authelia pass)
└─────────────────┘
```

**Security Layers**:
1. **Cloudflare** - DDoS protection, SSL termination
2. **NPM + Authelia** - 2FA gate (password + TOTP)
3. **WireGuard** - Photoprism only accessible on private network (10.0.0.2)
4. **Photoprism** - Internal auth (bypassed via Lua auto-login after 2FA)

**SSO Across Subdomains**:
```
                    Cookie: authelia_session
                    Domain: diegonmarcos.com
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   photos.    │  │   mail.      │  │   cal.       │
│diegonmarcos  │  │diegonmarcos  │  │diegonmarcos  │
│    .com      │  │    .com      │  │    .com      │
└──────────────┘  └──────────────┘  └──────────────┘
        │                  │                  │
        └──────────────────┴──────────────────┘
                           │
                    Same Authelia
                    Same 2FA session
```

**Flow Summary**:
```
1. User → photos.diegonmarcos.com
2. NPM → auth_request /authelia-verify
3. Authelia returns 401 (not authenticated)
4. NPM redirects → auth.diegonmarcos.com
5. User logs in (username + password + TOTP)
6. Authelia sets session cookie (path: /, domain: diegonmarcos.com)
7. Redirect back → photos.diegonmarcos.com
8. NPM → auth_request /authelia-verify → 200 OK
9. NPM proxies to Photoprism via WireGuard (with path rewrite)
```

**NPM Advanced Config (per proxy host)**:
```nginx
# Forward authentication to Authelia
location = /authelia-verify {
    internal;
    proxy_pass http://authelia:9091/api/verify;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

location /photoprism {
    auth_request /authelia-verify;
    error_page 401 =302 https://auth.diegonmarcos.com/?rd=$scheme://$http_host$request_uri;

    # Rewrite /photoprism to / for backend
    rewrite ^/photoprism(/.*)$ $1 break;
    rewrite ^/photoprism$ / break;

    proxy_pass http://10.0.0.2:2342;
    # ... other proxy headers
}
```

**Authelia Configuration**:
```yaml
# /config/authelia_config.yml
server:
  address: tcp://0.0.0.0:9091  # No base path

session:
  name: authelia_session
  secret: authelia-secret-change-me-in-production
  cookies:
    - name: authelia_session
      domain: diegonmarcos.com
      authelia_url: https://auth.diegonmarcos.com  # No /authelia base path
      inactivity: 5m
      expiration: 1h
      remember_me: 30d

access_control:
  default_policy: two_factor
  rules:
    - domain: auth.diegonmarcos.com
      policy: bypass
    - domain: '*.diegonmarcos.com'
      policy: two_factor

authentication_backend:
  file:
    path: /config/users_database.yml

totp:
  issuer: diegonmarcos.com
  period: 30
  skew: 1
```

### 7.11.1 Authelia OIDC Provider

Authelia is configured as an **OpenID Connect (OIDC) Identity Provider** to enable SSO for applications that don't support forward auth but do support OIDC (like NPM admin panel).

**OIDC Architecture**:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OIDC AUTHENTICATION FLOW                             │
└─────────────────────────────────────────────────────────────────────────────┘

Browser: https://proxy.diegonmarcos.com
         │
         ▼
┌─────────────────┐
│   CLOUDFLARE    │  DNS resolves to GCP IP (35.226.147.64)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   NPM Proxy     │  Routes to oauth2-proxy-npm
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  oauth2-proxy   │  Checks for valid OIDC session
│  (Port 4180)    │  No session → redirect to Authelia OIDC
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  AUTHELIA OIDC  │  /api/oidc/authorization
│  (Port 9091)    │  User authenticates (password + TOTP)
└────────┬────────┘
         │
         │  Authorization code + redirect
         ▼
┌─────────────────┐
│  oauth2-proxy   │  Exchanges code for tokens
│  /oauth2/callback│  Sets session cookie (_oauth2_proxy)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   NPM Admin     │  User accesses NPM without NPM's own login
│   (Port 81)     │  Headers: X-User, X-Email from oauth2-proxy
└─────────────────┘
```

**OIDC Configuration in Authelia**:
```yaml
# ~/authelia/config/configuration.yml

identity_providers:
  oidc:
    hmac_secret: '<random-hex-string>'
    jwks:
      - key_id: 'main'
        algorithm: 'RS256'
        use: 'sig'
        key: |
          -----BEGIN PRIVATE KEY-----
          <RSA private key>
          -----END PRIVATE KEY-----
    clients:
      - client_id: 'oauth2-proxy-npm'
        client_name: 'NPM Proxy Manager'
        client_secret: '$plaintext$<secret>'
        public: false
        authorization_policy: 'two_factor'
        consent_mode: implicit  # Skip consent screen for SSO UX
        redirect_uris:
          - 'https://proxy.diegonmarcos.com/oauth2/callback'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
          - 'groups'
        userinfo_signed_response_alg: 'none'
        token_endpoint_auth_method: 'client_secret_basic'
```

**oauth2-proxy Configuration**:
```yaml
# ~/oauth2-proxy-npm/docker-compose.yml
services:
  oauth2-proxy-npm:
    image: quay.io/oauth2-proxy/oauth2-proxy:latest
    container_name: oauth2-proxy-npm
    command:
      - --http-address=0.0.0.0:4180
      - --provider=oidc
      - --client-id=oauth2-proxy-npm
      - --client-secret=<secret>
      - --redirect-url=https://proxy.diegonmarcos.com/oauth2/callback
      - --oidc-issuer-url=https://auth.diegonmarcos.com
      - --cookie-secret=<32-byte-hex>
      - --cookie-domain=.diegonmarcos.com
      - --upstream=http://npm:81
      - --skip-provider-button=true
      - --pass-user-headers=true
    networks:
      - npm_default
```

**NPM Nginx Config for OIDC**:
```nginx
# proxy.diegonmarcos.com config

# oauth2-proxy endpoints
location /oauth2/ {
    proxy_pass http://oauth2-proxy-npm:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location = /oauth2/auth {
    proxy_pass http://oauth2-proxy-npm:4180;
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
    proxy_pass http://npm:81;
}
```

**Authentication Methods Summary**:
| Method | Use Case | Services |
|--------|----------|----------|
| **Forward Auth** | Services behind NPM that support auth_request | photos, mail, analytics |
| **OIDC** | Apps that need bypass of their own auth | proxy (NPM admin) |
| **Native Auth** | Services with their own authentication | Matomo, Mailu admin |

### 7.12 Network Isolation Strategy

**Rule: Services on different VMs MUST use one of:**

| Scenario | Solution | Security Level |
|----------|----------|----------------|
| Same VM, same compose | Docker internal network | High |
| Same VM, different compose | Shared Docker network | Medium-High |
| Different VMs, same provider | VPC/VCN private subnet | Medium |
| Different VMs, different providers | WireGuard tunnel | High |
| Any public exposure | Authelia 2FA + IP whitelist | High |

**Docker Compose Best Practices**:
```yaml
# CORRECT: Internal network for databases
networks:
  frontend:
    driver: bridge
  backend:
    internal: true  # No internet access

services:
  app:
    networks:
      - frontend
      - backend
  db:
    networks:
      - backend  # Database NEVER on frontend network
```

**Firewall + Docker Integration**:
```bash
# Block direct access to service port, allow only from NPM proxy
sudo iptables -I INPUT 1 -p tcp --dport 8080 -s 35.226.147.64 -j ACCEPT
sudo iptables -I INPUT 2 -p tcp --dport 8080 -j DROP

# Persist rules
sudo iptables-save > /etc/iptables/rules.v4
```

### 7.13 Security Checklist

| Item | Status | Notes |
|------|--------|-------|
| All containers bind to 127.0.0.1 or internal network | ✓ | Prevents Docker UFW bypass |
| WireGuard tunnel for cross-VM communication | ✓ | GCP ↔ Oracle |
| Authelia 2FA on sensitive services | ✓ | Photoprism, admin panels |
| UFW enabled with default deny | ✓ | All VMs |
| SSH key-only authentication | ✓ | No passwords |
| Let's Encrypt SSL on all domains | ✓ | Auto-renewal via NPM |
| Database ports never exposed publicly | ✓ | Internal networks only |
| Firewall rules persist after reboot | ✓ | iptables-persistent |
| Public DNS (Google/Cloudflare) on all VMs | ✓ | Prevents ISP DNS filtering/poisoning |

**DNS Configuration (Required on all VMs):**

```bash
# /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4 1.0.0.1

# Apply with: sudo systemctl restart systemd-resolved
```

**Rationale:** Local/ISP DNS may filter or fail to resolve custom domains. Public DNS ensures reliable resolution.

### 7.14 Wake-on-Demand (Dormant VMs)

Some VMs (e.g., `oci-p-flex_1` running Photoprism) are configured to auto-stop after 30 minutes of idle time to reduce costs. The Cloud API provides wake-on-demand functionality.

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        WAKE-ON-DEMAND FLOW                                   │
└─────────────────────────────────────────────────────────────────────────────┘

User visits photos.diegonmarcos.com
         │
         ▼
┌─────────────────┐
│  MyPhotos Page  │  (GitHub Pages)
│  index.html     │
└────────┬────────┘
         │ checkServerStatus()
         ▼
┌─────────────────┐     ┌─────────────────┐
│   Cloud API     │────▶│   OCI API       │
│  api.diegon...  │     │  (Instance      │
│  /api/wake/*    │     │   actions)      │
└────────┬────────┘     └────────┬────────┘
         │                       │
         │ GET /api/wake/status  │ oci compute instance get
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│  Server Status  │     │  STOPPED → Wake │
│  RUNNING/STOPPED│     │  via OCI API    │
└────────┬────────┘     └─────────────────┘
         │
         │ If STOPPED: Show "Wake Server" button
         │ If RUNNING: Hide button, proceed to login
         ▼
┌─────────────────┐
│  POST /api/wake │  (User clicks wake button)
│     /trigger    │
└────────┬────────┘
         │ oci compute instance action --action START
         │ Poll until RUNNING + WireGuard handshake
         ▼
┌─────────────────┐
│  Photoprism     │  (10.0.0.2:2342 via WireGuard)
│  now accessible │
└─────────────────┘
```

**API Endpoints**:
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/wake/status` | GET | Returns VM state (RUNNING, STOPPED, STARTING) |
| `/api/wake/trigger` | POST | Starts the dormant VM via OCI API |

**Frontend Integration** (myphotos/src/index.html):
```javascript
const CLOUD_API = 'https://api.diegonmarcos.com';

// Check if server is up
async function checkServerStatus() {
    const response = await fetch(`${CLOUD_API}/api/wake/status`);
    const data = await response.json();
    // Show/hide wake button based on state
}

// Wake dormant server
async function wakeServer() {
    await fetch(`${CLOUD_API}/api/wake/trigger`, { method: 'POST' });
    // Poll until server is ready
}
```

**Dormant VMs**:
| VM | Services | Idle Timeout | Wake Time |
|----|----------|--------------|-----------|
| oci-p-flex_1 (84.235.234.87) | Photoprism, Gitea | 30 min | ~60-90s |

**WireGuard Reconnection**:
After wake, the WireGuard peer (10.0.0.2) takes ~30s to re-establish handshake with GCP (10.0.0.1). The API polls the WireGuard status before reporting the VM as fully ready.

---

# PART IV: DATA

## 8. Volume & Storage Strategy

### 8.0 Storage Overview

| Storage Type | Location | Capacity | Used | Purpose | Cost |
|--------------|----------|----------|------|---------|------|
| **VM Boot Disk** | oci-f-micro_1 | 47 GB | ~13 GB | OS, Docker, Mail | $0 (Free) |
| **VM Boot Disk** | oci-f-micro_2 | 47 GB | ~12 GB | OS, Docker, Matomo | $0 (Free) |
| **VM Boot Disk** | gcp-f-micro_1 | 30 GB | ~8 GB | OS, NPM, Authelia | $0 (Free) |
| **VM Boot Disk** | oci-p-flex_1 | 100 GB | ~13 GB | OS, Docker, Services | $5.50/mo |
| **Object Storage** | oracle_s3:my-photos | Unlimited | ~204 GB | Google Photos Takeout | ~$5/mo |
| **Object Storage** | oracle_s3:archlinux-images | Unlimited | ~2 GB | Arch Linux images | ~$0.05/mo |

**Oracle Object Storage Buckets:**

| Bucket | Contents | Size | Access |
|--------|----------|------|--------|
| `my-photos` | Google Takeout zips, extracted photos | ~204 GB | `rclone oracle_s3:my-photos/` |
| `archlinux-images` | Arch Linux VM images | ~2 GB | `rclone oracle_s3:archlinux-images/` |

**Rclone Remotes Configured (oci-p-flex_1):**

| Remote | Type | Purpose |
|--------|------|---------|
| `gdrive:` | Google Drive | Access Google Drive files |
| `gdrive_photos:` | Google Photos | Access Google Photos |
| `oracle_s3:` | Oracle Object Storage | S3-compatible bucket storage |

### 8.1 Storage Partitions (ARM Server - Future)

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

### 8.2 LUKS Encryption Setup

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

---

## 9. Database Strategy

### 9.1 SQL vs NoSQL Decision Matrix

| Use Case | Type | Database | Reason |
|----------|------|----------|--------|
| Analytics (Matomo) | SQL | MariaDB | Complex queries, time-series |
| User Files (NextCloud) | SQL | PostgreSQL | Metadata, relations |
| Mail Accounts | SQL | SQLite | Simple, lightweight |
| Session Cache | NoSQL | Redis | Fast, ephemeral |
| Search Index | NoSQL | Redis | Key-value lookups |
| Email Storage | Files | Maildir | Standard format |

### 9.2 Isolation Rule

```
+-------------------------------------------------------------+
|                    RULE: ONE DB PER SERVICE                  |
|                                                              |
|  WRONG: Single MariaDB for Matomo + NextCloud               |
|  RIGHT: Separate MariaDB (Matomo) + PostgreSQL (NC)         |
|                                                              |
|  Reason: Prevents privilege escalation between services     |
+-------------------------------------------------------------+
```

---

# PART V: OPERATIONS

## 10. SSH & Access Commands

### 10.1 SSH Access

```bash
# === OCI (Oracle Cloud) - Use SSH key ===
# Oracle Flex 1 - Main Services (Flask, Photos, Gitea)
ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@84.235.234.87

# Oracle Micro 1 - Mail Server (Mailu)
ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@130.110.251.193

# Oracle Micro 2 - Services
ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@129.151.228.66

# === GCP (Google Cloud) - Use gcloud CLI ===
# GCP Micro 1 (arch-1) - NPM, Authelia, OAuth2 Proxy
gcloud compute ssh arch-1 --zone=us-central1-a

# GCP with command execution
gcloud compute ssh arch-1 --zone=us-central1-a --command="sudo docker ps"

# GCP copy file from container
gcloud compute ssh arch-1 --zone=us-central1-a --command="sudo docker cp npm:/data/database.sqlite /tmp/npm.db && sqlite3 /tmp/npm.db 'SELECT * FROM user;'"
```

### 10.1.1 GCP SSH Notes
- **DO NOT use `ssh user@IP` for GCP** - use `gcloud compute ssh` instead
- gcloud handles key exchange automatically via OS Login
- Instance name: `arch-1`, Zone: `us-central1-a`
- External IP: `35.226.147.64` (use gcloud, not direct SSH)

### 10.2 Docker Commands (after SSH)

```bash
# View all containers
sudo docker ps

# View logs
sudo docker logs --tail 100 matomo-app
sudo docker logs --tail 100 -f matomo-db

# Execute shell in container
sudo docker exec -it matomo-app bash
sudo docker exec -it matomo-db bash
sudo docker exec -it mailu-admin sh

# Restart container
sudo docker restart matomo-app

# View resource usage
sudo docker stats --no-stream
```

### 10.3 System Commands

```bash
# Disk usage
df -h

# Memory usage
free -h

# Check swap
swapon --show

# Create swap (if needed - for 1GB VMs)
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## 11. Front-End Integration

### 11.0 Web Development Guidelines

All frontend development for the Cloud Dashboard **MUST** follow the web development standards defined in:

```
/front-Github_io/1.ops/
├── 0_Stack_Main.md           ← Technology stack & framework decisions
├── 1_Folder_Structure.md     ← Project structure & file organization
├── 2_Build_Deploy_Watch.md   ← Build scripts, CI/CD, dev servers
└── 3_Analytics.md            ← Matomo tracking & meta tags
```

**Cloud Dashboard Classification:**
| Project | Type | Framework | CSS | JS | Build | Port |
|---------|------|-----------|-----|-----|-------|------|
| Cloud | Type 3 (Private Dashboard) | Vanilla | Sass | TypeScript | CSR (Client-Side) | :8006 |

**Required Standards:**
1. **Stack**: Follow `0_Stack_Main.md` for framework selection and build strategy
2. **Structure**: Follow `1_Folder_Structure.md` for `src_vanilla/`, `dist/`, `public/` organization
3. **Build**: Use `cloud/1.ops/build.sh` which integrates with `1.ops/build_main.sh`
4. **Analytics**: Include Matomo Tag Manager header and custom tracking per `3_Analytics.md`
5. **CI/CD**: All builds must pass `.github/workflows/deploy.yml` pipeline

**Cross-Reference:**
- Frontend source: `/front-Github_io/cloud/src_vanilla/`
- Build script: `/front-Github_io/cloud/1.ops/build.sh`
- Symlink in backend: `/back-System/cloud/0.spec/front-cloud/` → `/front-Github_io/cloud/`

### 11.1 Data Source

The front-end dashboard reads from `cloud-infrastructure.json`:

- **Services list** → `services` object
- **VM cards** → `virtualMachines` object
- **Provider cards** → `providers` object
- **URLs & commands** → Each service/VM contains its URLs
- **Status indicators** → `status` field on each entity

### 11.2 JSON Structure Overview

```json
{
  "providers": {
    "oracle": { "consoleUrl": "...", "cli": {...} },
    "gcloud": { "consoleUrl": "...", "cli": {...} }
  },
  "vmCategories": {
    "services": { "name": "Services", "description": "..." },
    "ml": { "name": "Machine Learning", "description": "..." }
  },
  "virtualMachines": {
    "oracle-web-server-1": { "ip": "...", "ssh": {...}, "services": [...] },
    "oracle-services-server-1": { "ip": "...", "ssh": {...}, "services": [...] }
  },
  "serviceCategories": {
    "infra": { "name": "Infrastructure" },
    "productivity": { "name": "Productivity" },
    "web": { "name": "Web" },
    "ml": { "name": "Machine Learning" }
  },
  "services": {
    "matomo": { "urls": {...}, "docker": {...}, "status": "active" }
  },
  "domains": { "primary": "diegonmarcos.com", "subdomains": {...} },
  "firewallRules": { "oracle-web-server-1": [...] }
}
```

### 11.3 TypeScript Types (suggested)

```typescript
interface CloudInfrastructure {
  providers: Record<string, Provider>;
  vmCategories: Record<string, VMCategory>;
  virtualMachines: Record<string, VirtualMachine>;
  serviceCategories: Record<string, ServiceCategory>;
  services: Record<string, Service>;
  domains: DomainConfig;
  firewallRules: Record<string, FirewallRule[]>;
  dockerNetworks: Record<string, DockerNetwork>;
  quickCommands: QuickCommands;
}
```

### 11.4 Front-End Card Mapping

| Card | JSON Path | Click Action |
|------|-----------|--------------|
| Matomo Analytics | `services.matomo` | Open `urls.gui` |
| Radicale | `services.calendar` | Open `urls.gui` |
| Oracle Cloud | `providers.oracle` | Open `consoleUrl` |
| Google Cloud | `providers.gcloud` | Open `consoleUrl` |

### 11.5 Status Values

| Status | Display | Card Style | Description |
|--------|---------|------------|-------------|
| `on` | Online | Green indicator | Running and accessible |

### 11.6 Naming Convention

All services follow a consistent naming pattern:

| Pattern | Example | Description |
|---------|---------|-------------|
| `{service}-app` | `matomo-app`, `radicale-app` | Application/service container |
| `{service}-db` | `matomo-db`, `photoprism-db` | Database container |
| `npm-gcloud` | Central NPM proxy | Single reverse proxy on GCP |

---

## 12. Operations & Maintenance

### 12.1 Daily Operations

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

### 12.2 Weekly Operations

```bash
# Update containers
docker compose pull
docker compose up -d

# Clean old images
docker image prune -a --filter "until=168h"

# Verify backups
ls -la /backup/
```

### 12.3 Monthly Operations

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

### 12.4 Dashboard Usage

The unified `cloud-dashboard.py` provides three modes: TUI, API Server, and CLI.

```bash
# Launch interactive TUI dashboard
python cloud-dashboard.py

# Start Flask API server (for web dashboard)
python cloud-dashboard.py serve
python cloud-dashboard.py serve --debug

# Quick CLI status check
python cloud-dashboard.py status

# Help
python cloud-dashboard.py help
```

#### API Endpoints (when running `serve`)

| Endpoint | Description |
|----------|-------------|
| `GET /api/health` | API health check |
| `GET /api/vms` | List all VMs |
| `GET /api/vms/<id>` | Get VM details |
| `GET /api/vms/<id>/status` | VM health status (ping, SSH) |
| `GET /api/vms/<id>/containers` | Docker containers on VM |
| `GET /api/services` | List all services |
| `GET /api/services/<id>` | Get service details |
| `GET /api/services/<id>/status` | Service health status (HTTP check) |
| `GET /api/dashboard/summary` | Full dashboard with health checks |
| `GET /api/dashboard/quick-status` | Quick status (config only, no checks) |
| `GET /api/config` | Full JSON configuration |
| `POST /api/config/reload` | Reload configuration from disk |

#### TUI Commands

| Key | Action |
|-----|--------|
| `1` | VM Details |
| `2` | Container Status |
| `3` | Reboot VM |
| `4` | Restart Container |
| `5` | View Logs |
| `6` | Stop/Start Container |
| `7` | SSH to VM |
| `8` | Open URL |
| `S` | Quick Status |
| `R` | Refresh |
| `Q` | Quit |

### 12.5 Incident Response

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

## 12A. Monitoring Dashboard Specification

The web dashboard (`cloud_dash.html`) provides three monitoring sections with a unified data architecture.

### 12A.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MONITORING DASHBOARD                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  cloud_dash.json (Single Source of Truth - Architect Maintained)            │
│  ├── providers, vms, services, domains (existing)                           │
│  └── costs (NEW)                                                             │
│      ├── infra: { oracle: $0, gcloud: $0 }                                  │
│      └── ai: { claude: { pricing, budget, plan }, gemini: planned }         │
│                                                                              │
│  cloud_dash.py (Flask API Server - Port 5000)                               │
│  ├── /api/dashboard/summary  → Status tab data                              │
│  ├── /api/metrics/*          → Performance tab data                         │
│  └── /api/costs/*            → Cost tab data                                │
│      ├── /api/costs/infra    → Static from cloud_dash.json                  │
│      └── /api/costs/ai/*     → ccusage_report.py (reads config from JSON)   │
│                                                                              │
│  cloud_dash.html (Frontend - 3 Tabs)                                        │
│  ├── Status Tab     ✅ Implemented                                          │
│  ├── Performance Tab 📝 Pending (Tasks 2.2, 2.3)                            │
│  └── Cost Tab        📝 Pending (Tasks 2.4, 2.5)                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 12A.2 Section Overview

| Section | Purpose | Data Source | Update Frequency |
|---------|---------|-------------|------------------|
| **Status** | Live health of VMs and services | Flask API `/api/dashboard/summary` | 30s auto-refresh |
| **Performance** | Resource utilization metrics | Flask API `/api/metrics/*` | 60s auto-refresh |
| **Cost** | Usage costs (Infra + AI) | Flask API `/api/costs/*` | Daily aggregation |

### 12A.3 Status Section (Implemented)

Current implementation in `cloud_dash.html`:

**VM Status Table Columns:**
| Column | Data Source | Interaction |
|--------|-------------|-------------|
| Mode | `status` field | Badge (ON/DEV/HOLD) |
| VM | `displayName` | Static text |
| IP | `network.publicIp` | Click to copy |
| SSH | SSH command | Click to copy |
| RAM | `specs.memory` | Static range |
| Storage | `specs.storage` | Static range |
| Status | Live ping/SSH check | Auto-refresh indicator |
| Action | Reboot button | Requires OAuth |

**Service Status Table Columns:**
| Column | Data Source | Interaction |
|--------|-------------|-------------|
| Mode | `status` field | Badge (ON/DEV/HOLD) |
| Service | `displayName` | Static text |
| URL | `urls.gui` | Click to open |
| IP:Port | `network.publicIp:internalPort` | Click to copy |
| RAM | `resources.ram` | Static range |
| Storage | `resources.storage` | Static range |
| Status | Live HTTP check | Auto-refresh indicator |

**Status Indicator States:**
| State | CSS Class | Color | Meaning |
|-------|-----------|-------|---------|
| Online | `.live-status.online` | Green | Responding to ping/HTTP |
| Offline | `.live-status.offline` | Red | Not responding |
| Checking | `.live-status.checking` | Gray | Request in progress |
| Pending | `.live-status.pending` | Yellow | Waiting for resource |
| Dev | `.live-status.dev` | Blue | In development |
| Hold | `.live-status.hold` | Yellow | On hold |

### 12A.4 Performance Section (To Implement)

**Metrics to Track:**

| Metric | Per VM | Per Service | Per DB | Unit | Source |
|--------|:------:|:-----------:|:------:|------|--------|
| CPU Usage | ✓ | ✓ | ✓ | % | SSH `top` / Docker stats |
| RAM Usage | ✓ | ✓ | ✓ | MB/GB | SSH `free` / Docker stats |
| VRAM Usage | ✓ | - | - | MB/GB | SSH `nvidia-smi` (if GPU) |
| Storage Used | ✓ | ✓ | ✓ | GB | SSH `df` / Docker stats |
| Storage Available | ✓ | - | - | GB | SSH `df` |
| Bandwidth In | ✓ | ✓ | - | MB/s | SSH `vnstat` |
| Bandwidth Out | ✓ | ✓ | - | MB/s | SSH `vnstat` |
| Network I/O | - | ✓ | ✓ | MB | Docker stats |
| Connections | - | ✓ | ✓ | count | Service-specific |

**API Endpoints (To Implement):**
```
GET /api/metrics/vms                    # All VM metrics
GET /api/metrics/vms/<id>               # Single VM metrics
GET /api/metrics/vms/<id>/history       # Historical data (24h)
GET /api/metrics/services/<id>          # Service metrics
GET /api/metrics/services/<id>/history  # Historical data (24h)
```

**UI Components:**
- Gauge charts for CPU/RAM/Storage
- Sparkline graphs for historical trends
- Color-coded thresholds (Green <70%, Yellow 70-90%, Red >90%)

### 12A.5 Cost Section (To Implement)

Cost tracking is split into two categories, with configuration stored in `cloud_dash.json`.

#### JSON Configuration Schema (to add to cloud_dash.json)

```json
{
  "costs": {
    "infra": {
      "oracle": {
        "name": "Oracle Cloud",
        "tier": "always-free",
        "monthly": 0,
        "resources": {
          "vms": "2x E2.1.Micro + 1x A1.Flex",
          "storage": "200GB block",
          "bandwidth": "10TB egress"
        },
        "overageRates": {
          "storage": 0.0255,
          "bandwidth": 0.0085
        }
      },
      "gcloud": {
        "name": "Google Cloud",
        "tier": "free-tier",
        "monthly": 0,
        "resources": {
          "vms": "1x e2-micro",
          "storage": "30GB standard",
          "bandwidth": "1GB egress"
        }
      },
      "cloudflare": { "name": "Cloudflare", "tier": "free", "monthly": 0 },
      "letsencrypt": { "name": "Let's Encrypt", "tier": "free", "monthly": 0 }
    },
    "ai": {
      "claude": {
        "name": "Claude (Anthropic)",
        "plan": "max5x",
        "monthlyBudget": 100.00,
        "alertThresholds": [50, 75, 90, 100],
        "expensiveModelAlert": 10,
        "planLimits": {
          "pro": { "messages": 45, "tokens": 90000, "window": "5h" },
          "max5x": { "messages": 225, "tokens": 450000, "window": "5h" },
          "max20x": { "messages": 900, "tokens": 1800000, "window": "5h" }
        },
        "pricing": {
          "haiku": { "input": 0.80, "output": 4.00, "cacheRead": 0.08, "cacheCreate": 1.00 },
          "sonnet": { "input": 3.00, "output": 15.00, "cacheRead": 0.30, "cacheCreate": 3.75 },
          "opus": { "input": 15.00, "output": 75.00, "cacheRead": 1.50, "cacheCreate": 18.75 }
        },
        "dataSource": "ccusage"
      },
      "gemini": {
        "name": "Gemini (Google)",
        "status": "planned",
        "planLimits": {
          "flash": { "messages": 166, "tokens": 332000, "window": "24h" },
          "pro": { "messages": 33, "tokens": 66000, "window": "24h" }
        },
        "pricing": {
          "flash": { "input": 1.25, "output": 5.00, "cacheRead": 0.31 },
          "pro": { "input": 1.25, "output": 5.00, "cacheRead": 0.31 }
        },
        "dataSource": "tbd"
      }
    }
  }
}
```

#### Infra Costs (Fixed + Variable)

| Cost Type | Provider | Metric | Rate | Notes |
|-----------|----------|--------|------|-------|
| **VPS Fixed** | Oracle | Always Free | $0/mo | 2x E2.1.Micro + 1x A1.Flex |
| **VPS Fixed** | GCloud | Free Tier | $0/mo | 1x e2-micro |
| **Storage** | Oracle | Block Volume | $0.0255/GB/mo | Beyond free tier |
| **Bandwidth** | Oracle | Egress | $0.0085/GB | Beyond 10TB/mo |
| **Domain** | Cloudflare | DNS | $0/year | Free tier |
| **SSL** | Let's Encrypt | Certificates | $0 | Auto-renewed |

**API Endpoints:**
```
GET /api/costs/infra                    # Current month summary (from cloud_dash.json)
```

#### AI Costs (Pay-per-Use)

| Provider | Model | Input Tokens | Output Tokens | Cache Read | Cache Create |
|----------|-------|--------------|---------------|------------|--------------|
| **Anthropic** | Claude Haiku 3.5 | $0.80/1M | $4.00/1M | $0.08/1M | $1.00/1M |
| **Anthropic** | Claude Sonnet 4.5 | $3.00/1M | $15.00/1M | $0.30/1M | $3.75/1M |
| **Anthropic** | Claude Opus 4 | $15.00/1M | $75.00/1M | $1.50/1M | $18.75/1M |
| **Google** | Gemini Flash 3.0 | $1.25/1M | $5.00/1M | $0.31/1M | - |
| **Google** | Gemini Pro 3.0 | $1.25/1M | $5.00/1M | $0.31/1M | - |

**Data Flow (Simplified):**
```
~/.claude/projects/*.jsonl
    │
    └── ccusage CLI (npm package) ← Use directly, no wrapper needed!
            │
            └── cloud_dash.py calls subprocess.run(['ccusage', ...])
                    │
                    └── /api/costs/ai/* endpoints
```

**ccusage Commands (all support --json):**
```bash
ccusage blocks -a --json      # Current 5h block with projections, burn rate
ccusage daily --json -b       # Daily breakdown with model costs
ccusage monthly --json -b     # Monthly totals with model breakdown
ccusage weekly --json -b      # Weekly aggregation
ccusage session --json        # Per-conversation breakdown
ccusage blocks --live         # Real-time TUI monitoring
```

**API Endpoints (direct ccusage integration):**
```
GET /api/costs/ai/now      → ccusage blocks -a --json
GET /api/costs/ai/daily    → ccusage daily --json -b
GET /api/costs/ai/monthly  → ccusage monthly --json -b
GET /api/costs/ai/weekly   → ccusage weekly --json -b
```

**Flask Implementation (simple subprocess):**
```python
import subprocess, json

@app.route('/api/costs/ai/now')
def api_costs_ai_now():
    result = subprocess.run(['ccusage', 'blocks', '-a', '--json'],
                          capture_output=True, text=True, timeout=30)
    return jsonify(json.loads(result.stdout))

@app.route('/api/costs/ai/daily')
def api_costs_ai_daily():
    result = subprocess.run(['ccusage', 'daily', '--json', '-b'],
                          capture_output=True, text=True, timeout=30)
    return jsonify(json.loads(result.stdout))
```

**UI Components:**
- Current 5h window: Usage bar, token breakdown, burn rate
- Budget tracker: MTD vs limit, projected EOM cost
- Model distribution: Pie chart (Haiku/Sonnet/Opus %)
- Daily trend: Sparkline of cost over time
- Alerts: Warning when Opus > 10%, budget > 75%

### 12A.6 Dashboard Tab Structure

```
┌─────────────────────────────────────────────────────────────────┐
│  Cloud Dashboard                              [Login] [Refresh] │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐ ┌─────────────┐ ┌────────┐                       │
│  │  Status  │ │ Performance │ │  Cost  │                       │
│  └──────────┘ └─────────────┘ └────────┘                       │
│     ▲ Active                                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [Status Tab Content - VMs, Services, Live indicators]          │
│                                                                  │
│  OR                                                              │
│                                                                  │
│  [Performance Tab Content - Gauges, Sparklines, Metrics]        │
│                                                                  │
│  OR                                                              │
│                                                                  │
│  [Cost Tab Content - Infra costs, AI costs, Charts]             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

# PART VI: REFERENCE & DASHBOARD

## 13. Diagrams

### 13.1 High-Level Service Flow

```
User Request
     |
     v
+-----------+
|    DNS    | analytics.diegonmarcos.com → 130.110.251.193
+-----+-----+
      |
      v
+-----------+
| NPM (:443)| SSL Termination + Routing
+-----+-----+
      |
      v
+-----------+
|  Matomo   | localhost:8080 (Docker)
|  (:8080)  |
+-----------+
```

### 13.2 Mermaid: Infrastructure Tree

```mermaid
graph TD
    subgraph CLOUD["Cloud Infrastructure"]

        subgraph ORACLE["Oracle Cloud"]
            subgraph MAIL_VM["oci-f-micro_1 - 130.110.251.193"]
                subgraph DOCKER1["Docker Engine"]
                    MAILU["Mailu Mail Suite"]
                end
            end
            subgraph ANALYTICS_VM["oci-f-micro_2 - 129.151.228.66"]
                subgraph DOCKER2["Docker Engine"]
                    MATOMO["Matomo :8080"]
                    MARIADB["MariaDB :3306"]
                end
            end
            subgraph DEV_VM["oci-p-flex_1 - 84.235.234.87 (Wake-on-Demand)"]
                subgraph DOCKER3["Docker Engine"]
                    PHOTOPRISM["Photoprism :2342"]
                    RADICALE["Radicale :5232"]
                    REDIS["Redis :6379"]
                end
            end
        end

        subgraph GCLOUD["Google Cloud - Free Tier"]
            subgraph PROXY_VM["gcp-f-micro_1 - 35.226.147.64"]
                NPM["NPM (Central) :80, :443, :81"]
                AUTHELIA["Authelia :9091"]
                FLASK["Flask API :5000"]
            end
        end

    end

    subgraph EXTERNAL["External Access"]
        INTERNET["Internet"]
        ANALYTICS["analytics.diegonmarcos.com"]
        PHOTOS["photos.diegonmarcos.com"]
        MAILDOM["mail.diegonmarcos.com"]
    end

    INTERNET --> NPM
    NPM --> ANALYTICS
    NPM --> PHOTOS
    ANALYTICS --> MATOMO
    PHOTOS --> PHOTOPRISM
    MAILDOM --> MAILU
    MATOMO --> MARIADB
```

### 13.3 Mermaid: Budget Protection Flow (GCloud)

```mermaid
sequenceDiagram
    participant GCP as GCP Services
    participant Budget as Budget Alert
    participant PubSub as Pub/Sub
    participant Function as Cloud Function
    participant Billing as Billing API

    GCP->>Budget: Spending reaches limit
    Budget->>PubSub: Publish alert message
    PubSub->>Function: Trigger billing-disabler
    Function->>Billing: Disable project billing
    Billing-->>GCP: Services stopped
    Note over GCP: Manual re-enable required
```

---

## 14. Authentication & Admin API

### 14.1 Overview

The dashboard supports **GitHub OAuth 2.0** authentication for admin operations. Public endpoints (status, health) remain unauthenticated. Admin endpoints (reboot, restart, stop/start) require login.

### 14.2 Authentication Flow

```
+------------------+     +------------------+     +------------------+
|   Dashboard UI   |     |   Flask API      |     |   GitHub OAuth   |
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
         | 1. Click "Login"       |                        |
         |----------------------->|                        |
         |                        | 2. Redirect to GitHub  |
         |                        |----------------------->|
         |                        |                        |
         |                        | 3. User authorizes     |
         |                        |<-----------------------|
         |                        |                        |
         | 4. Return JWT token    |                        |
         |<-----------------------|                        |
         |                        |                        |
         | 5. Admin commands      |                        |
         | (with Bearer token)    |                        |
         |----------------------->|                        |
         |                        |                        |
```

### 14.3 Endpoint Access Levels

| Access Level | Endpoints | Auth Required |
|--------------|-----------|---------------|
| **Public** | `/api/health`, `/api/vms`, `/api/services`, `/api/dashboard/*` | No |
| **Admin** | `/api/admin/vms/*/reboot`, `/api/admin/vms/*/containers/*/restart` | Yes (JWT) |

### 14.4 Admin API Endpoints

| Endpoint | Method | Description | Auth |
|----------|--------|-------------|------|
| `POST /api/auth/github` | POST | Initiate GitHub OAuth flow | No |
| `GET /api/auth/callback` | GET | GitHub OAuth callback | No |
| `GET /api/auth/me` | GET | Get current user info | Yes |
| `POST /api/auth/logout` | POST | Invalidate session | Yes |
| `POST /api/admin/vms/<id>/reboot` | POST | Reboot VM via SSH | Yes |
| `POST /api/admin/vms/<id>/containers/<name>/restart` | POST | Restart Docker container | Yes |
| `POST /api/admin/vms/<id>/containers/<name>/stop` | POST | Stop Docker container | Yes |
| `POST /api/admin/vms/<id>/containers/<name>/start` | POST | Start Docker container | Yes |
| `POST /api/admin/services/<id>/restart` | POST | Restart service (container) | Yes |

### 14.5 GitHub OAuth Configuration

```bash
# Required environment variables
GITHUB_CLIENT_ID=your_client_id
GITHUB_CLIENT_SECRET=your_client_secret
JWT_SECRET_KEY=your_jwt_secret
ALLOWED_GITHUB_USERS=diegonmarcos  # Comma-separated usernames
```

GitHub App settings:
- **Authorization callback URL**: `https://cloud.diegonmarcos.com/api/auth/callback`
- **Scopes**: `read:user` (only need username verification)

### 14.6 Dashboard UI Changes

**Before Login:**
```
+------------------------------------------+
|  Cloud Dashboard            [Login] btn  |
+------------------------------------------+
|  VMs        | Services                   |
|  - Status   | - Status                   |
|  (read-only)| (read-only)                |
+------------------------------------------+
```

**After Login:**
```
+------------------------------------------+
|  Cloud Dashboard    [diego] [Logout] btn |
+------------------------------------------+
|  VMs                | Services           |
|  - Status           | - Status           |
|  - [Reboot] btn     | - [Restart] btn    |
|  - [Containers]     | - [Stop/Start]     |
|    - [Restart]      |                    |
|    - [Stop/Start]   |                    |
+------------------------------------------+
```

### 14.7 Security Considerations

1. **JWT Expiration**: Tokens expire after 24 hours
2. **Username Whitelist**: Only `ALLOWED_GITHUB_USERS` can access admin endpoints
3. **HTTPS Only**: OAuth flow requires HTTPS
4. **CSRF Protection**: State parameter in OAuth flow
5. **Rate Limiting**: Admin endpoints rate-limited to prevent abuse
6. **Audit Logging**: All admin actions logged with timestamp and user

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-14 | **v3.5.0** - Removed all dev/hold/backlog items, keeping only active services |
| 2025-12-14 | Removed ML VMs, ARM server, and all dev services (git, vpn, terminal, cryptpad, cache) |
| 2025-12-14 | Simplified status to single `on` value |
| 2025-12-14 | **v3.4.0** - Reorganized folder structure to `a_solutions/` and `b_infra/` separation |
| 2025-12-14 | Solutions grouped by domain (analytics, api, mail, photos, etc.) |
| 2025-12-14 | Infrastructure grouped by VM identifier (oci-p-flex_1, gcp-f-micro_1, etc.) |
| 2025-12-14 | Added Structure Philosophy table explaining the new layout |
| 2025-12-04 | **v3.2.0** - Added Section 15 (Dashboard Architecture) and Section 16 (Frontend Views Spec) |
| 2025-12-04 | Detailed Source of Truth hierarchy with 4-layer flow diagram |
| 2025-12-04 | Added Runtime Data Flow diagram (Browser → GitHub Pages → Flask API → JSON) |
| 2025-12-04 | Documented JS-to-API integration with code examples |
| 2025-12-04 | Added Front/Back view specs with Card and List layouts |
| 2025-12-04 | Updated Cloud-spec_Tables.md header as proper Frontend Specification |
| 2025-12-04 | **v3.1.0** - Added OAuth 2.0 (GitHub) authentication spec for admin endpoints |
| 2025-12-03 | **v3.0.0** - Unified cloud-dashboard.py (TUI + Flask API in single file) |
| 2025-12-03 | Established naming convention: `{service}-app`, `{service}-db`, `npm-{provider}-{vm}` |
| 2025-12-03 | Established status value: `on` for active services |
| 2025-12-03 | Added `displayName` field for human-readable service names |
| 2025-12-03 | Created Cloud-spec_Tables.md with architecture reference tables |
| 2025-12-02 | Consolidated HANDOFF.md, spec_infra.md, SPEC.md, VPS_ARCHITECTURE_SPEC.md into single CLOUD-SPEC.md |
| 2025-12-02 | Reorganized VMs and services with categories |
| 2025-12-01 | Migrated to JSON data source, deprecated CSV |
| 2025-11-27 | Added services-server-1 |
| 2025-11-26 | Initial infrastructure documentation |

---

## File Structure

```
/home/diego/Documents/Git/back-System/cloud/
│
├── 0.spec/                                 ← SPECS & RESEARCH
│   ├── TASKS_OVERVIEW.md                   ← Task management and project structure
│   ├── Research/                           ← Research and reference materials
│   └── archive/                            ← Archived specs
│
├── 1.ops/                                  ← OPERATIONS & ORCHESTRATION
│   ├── Cloud-spec_.md                      ← Main specification (this file)
│   ├── Cloud-spec_Tables.md                ← Architecture reference tables
│   ├── cloud_dash.json                     ← PRIMARY DATA SOURCE (JSON)
│   ├── cloud_dash.py                       ← UNIFIED DASHBOARD (TUI + Flask API)
│   ├── front-cloud/                        ← Symlink to website repo
│   ├── AI_Dashboard/                       ← Symlink to AI dashboard
│   └── vm-control.sh                       ← VM control scripts
│
├── a_solutions/                            ← APPLICATIONS & SERVICES (by solution)
│   │
│   ├── analytics/                          ← Matomo Analytics
│   │   ├── analytics-app/                  ← Matomo application
│   │   │   ├── docker-compose.yml
│   │   │   ├── scripts/                    ← Setup & management scripts
│   │   │   └── tags/                       ← Tracking tags per project
│   │   └── analytics-db/                   ← MariaDB for Matomo
│   │       └── docker-compose.yml
│   │
│   ├── api/                                ← Cloud API & Dashboard Backend
│   │   ├── src/                            ← Source files (JSON, JS, Python)
│   │   │   ├── cloud_dash.json             ← Infrastructure data
│   │   │   ├── cloud_dash.py               ← Dashboard script
│   │   │   └── openapi.yaml                ← API specification
│   │   ├── flask-app/                      ← Flask API server
│   │   │   ├── app/                        ← Flask application modules
│   │   │   ├── docker-compose.yml
│   │   │   └── requirements.txt
│   │   ├── db/                             ← API database
│   │   └── dist/                           ← Built/exported files
│   │
│   ├── calendar/                           ← Radicale Calendar
│   │   └── calendar-app/
│   │       ├── docker-compose.yml
│   │       └── config/
│   │
│   ├── db_cache/                           ← Redis Cache
│   │   └── cache-app/
│   │       └── docker-compose.yml
│   │
│   ├── mail/                               ← Mailu Mail Server
│   │   ├── mail-app/                       ← Mailu containers
│   │   │   ├── docker-compose.yml
│   │   │   ├── cloudflare-worker/          ← Email routing worker
│   │   │   └── smtp-proxy/                 ← SMTP proxy config
│   │   └── mail-db/
│   │       └── docker-compose.yml
│   │
│   ├── npm/                                ← Nginx Proxy Manager
│   │   └── npm-app/
│   │       └── docker-compose.yml
│   │
│   ├── photos/                             ← Photoprism Photo Gallery
│   │   └── photos-webhook/                 ← Webhook handler
│   │       ├── docker-compose.yml
│   │       └── webhook.py
│   │
│   │
│   ├── vault/                              ← Vaultwarden (Bitwarden)
│   │   └── vault-app/
│   │       └── docker-compose.yml
│   │
│   ├── vpn/                                ← VPN Server
│   │   └── vpn-app/
│   │       └── docker-compose.yml
│   │
│   └── web_front/                          ← Static Web Frontend
│
└── b_infra/                                ← INFRASTRUCTURE (by VM/machine)
    │
    ├── gcp-f-micro_1/                      ← GCloud Free e2-micro (NPM + Authelia)
    │   └── 1.os/
    │       └── gcp-f-micro_1.md            ← VM spec & config
    │
    ├── oci-f-micro_1/                      ← Oracle Free E2.Micro (Mail)
    │   └── 1.os/
    │       └── oci-f-micro_1.md
    │
    ├── oci-f-micro_2/                      ← Oracle Free E2.Micro (Analytics)
    │   └── 1.os/
    │       └── oci-f-micro_2.md
    │
    ├── oci-p-flex_1/                       ← Oracle Paid E4.Flex (Wake-on-Demand)
    │   └── 1.os/
    │       ├── oci-p-flex_1.md
    │       ├── idle-shutdown.sh            ← Auto-shutdown script
    │       ├── idle-shutdown.service       ← Systemd service
    │       └── idle-shutdown.timer         ← Systemd timer
    │
    ├── local_SurfacePro8/                  ← Local Development Machine
    │   ├── 1.spec/                         ← Hardware specs
    │   │   └── surface-pro-8.md
    │   ├── 2.app/                          ← App documentation
    │   │   ├── dev-tools.md
    │   │   ├── cli-tools.md
    │   │   └── gui-apps.md
    │   ├── 3.config/                       ← Shell & config backups
    │   │   └── backup/                     ← bashrc, zshrc, etc.
    │   ├── 4.secrets/                      ← Local secrets (gitignored)
    │   └── migration_plan/                 ← OS migration scripts
    │       └── migration-scripts/
    │
    ├── vps_oracle/                         ← Oracle Cloud provider-level docs
    │   └── README.md
    │
    └── vps_gcloud/                         ← GCloud provider-level docs
        └── billing/
            └── billing-disabler/           ← Budget protection automation
                ├── main.py
                ├── budget-config.yaml
                └── requirements.txt
```

### Structure Philosophy

| Layer | Folder | Purpose | Naming Convention |
|-------|--------|---------|-------------------|
| **Specs** | `0.spec/` | Documentation, research, task tracking | `*.md` |
| **Ops** | `1.ops/` | Orchestration, dashboards, CI/CD | `*.sh`, `*.py` |
| **Solutions** | `a_solutions/` | Applications grouped by solution domain | `{solution}/{solution}-app/` |
| **Infrastructure** | `b_infra/` | VMs & machines, grouped by identifier | `{vm-id}/1.os/` |

**Key Principles:**
1. **Solutions are portable** - `a_solutions/` contains docker-compose files that can be deployed to any VM
2. **Infrastructure is machine-specific** - `b_infra/` contains OS configs, systemd services, and VM specs
3. **Separation of concerns** - What to deploy (solutions) vs Where to deploy (infra)

### Source of Truth Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SOURCE OF TRUTH FLOW                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. DESIGN LAYER (Human-Authored)                                           │
│     ┌──────────────────────────────────────────────────────────────┐        │
│     │  Cloud-spec_.md          Cloud-spec_Tables.md                │        │
│     │  ├─ Architecture text    ├─ Service Registry tables          │        │
│     │  ├─ Security specs       ├─ Resource matrices                │        │
│     │  ├─ Network design       ├─ Mermaid diagrams (baseline)      │        │
│     │  └─ API documentation    └─ Status monitoring tables         │        │
│     └──────────────────────────────────────────────────────────────┘        │
│                                    │                                         │
│                                    ▼                                         │
│  2. DATA LAYER (Machine-Readable)                                           │
│     ┌──────────────────────────────────────────────────────────────┐        │
│     │  cloud-infrastructure.json (cloud_dash.json)                 │        │
│     │  ├─ VMs: IPs, specs, SSH config                              │        │
│     │  ├─ Services: URLs, ports, Docker config                     │        │
│     │  ├─ Providers: Console URLs, CLI commands                    │        │
│     │  └─ Resources: RAM, storage, bandwidth estimates             │        │
│     └──────────────────────────────────────────────────────────────┘        │
│                                    │                                         │
│                                    ▼                                         │
│  3. API LAYER (Flask Server)                                                │
│     ┌──────────────────────────────────────────────────────────────┐        │
│     │  cloud_dash.py (TUI + Flask API)                             │        │
│     │  ├─ Reads JSON config                                        │        │
│     │  ├─ Performs health checks (ping, SSH, HTTP)                 │        │
│     │  ├─ Exposes REST API endpoints                               │        │
│     │  └─ Handles OAuth authentication                             │        │
│     └──────────────────────────────────────────────────────────────┘        │
│                                    │                                         │
│                                    ▼                                         │
│  4. PRESENTATION LAYER (Frontend)                                           │
│     ┌──────────────────────────────────────────────────────────────┐        │
│     │  front-cloud/ (HTML/CSS/JS)                                  │        │
│     │  ├─ cloud_dash.html: Fetches data via JS from Flask API      │        │
│     │  ├─ arch.html: Renders Mermaid diagrams as HTML              │        │
│     │  ├─ ai-arch.html: AI architecture visualization              │        │
│     │  └─ index.html: Navigation hub                               │        │
│     └──────────────────────────────────────────────────────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow: How Components Interact

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RUNTIME DATA FLOW                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  User Browser                                                                │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────┐    HTTP GET     ┌─────────────────────────────────┐    │
│  │  cloud_dash.html │ ─────────────► │  GitHub Pages / Static Host     │    │
│  │  (Static HTML)   │ ◄───────────── │  (diegonmarcos.github.io/cloud) │    │
│  └────────┬─────────┘    HTML/JS     └─────────────────────────────────┘    │
│           │                                                                  │
│           │ JavaScript fetch()                                               │
│           ▼                                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │  Flask API (cloud.diegonmarcos.com/api/*)                       │        │
│  │                                                                  │        │
│  │  GET /api/vms              → List all VMs from JSON             │        │
│  │  GET /api/vms/<id>/status  → Live health check (ping, SSH)      │        │
│  │  GET /api/services         → List all services from JSON        │        │
│  │  GET /api/services/<id>/status → Live HTTP check                │        │
│  │  GET /api/dashboard/summary    → Full dashboard with checks     │        │
│  │  POST /api/vm/<id>/reboot      → Admin action (requires OAuth)  │        │
│  └────────┬─────────────────────────────────────────────────────────┘        │
│           │                                                                  │
│           │ Reads                                                            │
│           ▼                                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │  cloud_dash.json (cloud-infrastructure.json)                    │        │
│  │  Single source of truth for all infrastructure data             │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 15. Dashboard Architecture

### 15.1 Overview

The Cloud Dashboard consists of three main components:

| Component | Technology | Location | Purpose |
|-----------|------------|----------|---------|
| **cloud-app** | HTML/CSS/JS | GitHub Pages | Static frontend UI |
| **flask-app** | Python Flask | Oracle VM | REST API + OAuth |
| **cloud_dash.json** | JSON | Oracle VM | Infrastructure data |

### 15.2 Frontend-to-API Integration

The frontend HTML fetches all data dynamically from the Flask API via JavaScript:

```javascript
// Frontend JavaScript (cloud_dash.html)

// 1. Fetch VM list on page load
async function loadVMs() {
    const response = await fetch('https://cloud.diegonmarcos.com/api/vms');
    const vms = await response.json();
    renderVMTable(vms);
}

// 2. Fetch live status for each VM
async function checkVMStatus(vmId) {
    const response = await fetch(`https://cloud.diegonmarcos.com/api/vms/${vmId}/status`);
    const status = await response.json();
    updateStatusIndicator(vmId, status);
}

// 3. Admin actions (requires OAuth token)
async function rebootVM(vmId) {
    const token = localStorage.getItem('github_token');
    const response = await fetch(`https://cloud.diegonmarcos.com/api/vm/${vmId}/reboot`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${token}` }
    });
    return response.json();
}
```

### 15.3 API Endpoint → Frontend Mapping

| Frontend Feature | API Endpoint | Data Used |
|------------------|--------------|-----------|
| VM Table | `GET /api/vms` | name, IP, status, services |
| VM Status Indicators | `GET /api/vms/<id>/status` | ping, ssh, uptime |
| Service Cards | `GET /api/services` | name, URL, status |
| Service Health | `GET /api/services/<id>/status` | http_check, response_time |
| Reboot Button | `POST /api/vm/<id>/reboot` | success/error message |
| Login State | `GET /api/auth/me` | username, avatar |

### 15.4 Architecture Visualization Pages

The dashboard includes pages that render Mermaid diagrams from the spec files:

| Page | Source | Content |
|------|--------|---------|
| `arch.html` | Cloud-spec_Tables.md (Mermaid) | Infrastructure tree diagram |
| `ai-arch.html` | Cloud-spec_Tables.md (Mermaid) | AI services architecture |

**Rendering Process:**
1. Mermaid code is authored in `Cloud-spec_Tables.md` (source of truth)
2. HTML pages include Mermaid.js library
3. Mermaid code is embedded in `<pre class="mermaid">` blocks
4. Mermaid.js renders SVG diagrams at runtime

---

## 16. Frontend Views Specification

### 16.1 Page Structure

The dashboard is organized into distinct views:

```
index.html (Navigation Hub)
├── Services Section
│   ├── Front View (User-Facing Services)
│   │   ├── Card View: Visual cards with icons
│   │   └── List View: Sortable table with status
│   └── Back View (Infrastructure Services)
│       ├── Card View: Admin service cards
│       └── List View: Detailed status table
│
├── Architecture Section
│   ├── Resources: Resource allocation charts
│   ├── Server: Infrastructure tree (arch.html)
│   └── AI: AI architecture (ai-arch.html)
│
└── Monitoring Section
    ├── Backlog: Pending tasks and issues
    ├── Status Tree: Hierarchical health view
    └── Status List: Flat table view (cloud_dash.html)
```

### 16.2 Front View (User-Facing Services)

**Card Layout: 3 Columns**

| User | Coder |
|------|-------|
| photos-app | matomo-app |
| mail-app | calendar-app |

**Card Component:**
```
┌─────────────────────────┐
│  📷 Photoprism          │  ← Icon + Display Name
│  ───────────────────    │
│  photos.diegonmarcos.com│  ← URL (clickable)
│  Status: ● Online       │  ← Live status indicator
│  [Open] [Copy SSH]      │  ← Action buttons
└─────────────────────────┘
```

### 16.3 Back View (Infrastructure Services)

**Card Layout: 2 Columns**

| Root (Cloud Management) | Infra (Service Infrastructure) |
|-------------------------|--------------------------------|
| **Cloud Providers** | **User Services** |
| - Oracle Cloud Console | - photos-app, mail-app, calendar-app |
| - Google Cloud Console | **Databases** |
| **VMs (SSH Access)** | - matomo-db, git-db, etc. |
| - oracle-web-server-1 | **Infra Services** |
| - oracle-services-server-1 | - flask-app, cache-app |
| - oracle-arm-server | **Proxies** |
| - gcloud-arch-1 | - npm-gcloud (SINGLE CENTRAL PROXY)

### 16.4 List View Columns

**Services List:**
| Column | Source | Notes |
|--------|--------|-------|
| Mode | `status` field | on/dev/hold/tbd |
| Service | `displayName` | Human-readable name |
| IP:Port | `network.publicIp` + `network.internalPort` | Click to copy |
| URL | `urls.gui` | Click to open |
| SSH | `ssh.command` | Click to copy |
| RAM | `resources.ram` | From JSON estimates |
| Storage | `resources.storage` | From JSON estimates |
| Status | Live API check | Green/Yellow/Red indicator |

**VMs List:**
| Column | Source | Notes |
|--------|--------|-------|
| Mode | `status` field | on/dev/hold/tbd |
| VM | `displayName` | Human-readable name |
| IP | `network.publicIp` | Click to copy |
| SSH | SSH command | Click to copy |
| Services | Count of hosted services | Expandable list |
| RAM | `specs.memory` | VM specification |
| Storage | `specs.storage` | VM specification |
| Status | Live ping/SSH check | Green/Yellow/Red indicator |

### 16.5 View Toggle Behavior

```
┌─────────────────────────────────────────────────────────────┐
│  Services                                                    │
│  ┌──────────┐ ┌──────────┐    ┌──────┐ ┌──────┐            │
│  │  Front   │ │   Back   │    │ Cards│ │ List │            │
│  └──────────┘ └──────────┘    └──────┘ └──────┘            │
│     ▲ Active                     ▲ Active                   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                     │
│  │  User   │  │  Coder  │  │   AI    │    ← Column headers │
│  ├─────────┤  ├─────────┤  ├─────────┤                     │
│  │ 📷 Photo│  │ 📊 Stats│  │ 🤖 AI   │                     │
│  │ 📧 Mail │  │ 📅 Cal  │  │         │                     │
│  │ 🔐 Auth │  │ 💻 API  │  │         │                     │
│  └─────────┘  └─────────┘  └─────────┘                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

**Maintainer**: Diego Nepomuceno Marcos
**Last Updated**: 2025-12-23
