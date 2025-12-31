# Cloud Infrastructure

Self-hosted cloud services and infrastructure management.

---

## 🌐 Quick Access

**[Cloud Dashboard](front-cloud/index.html)** - Main web interface for all services

---

## 📂 Service Directory

### Active Services

#### **[Analytics](analytics/matomo/)**
- **Status**: ✅ Active
- **Service**: Matomo Analytics
- **URL**: https://analytics.diegonmarcos.com
- **Server**: Oracle Cloud (EU-Marseille-1)
- **Purpose**: Website analytics and tracking

#### **[VPS Oracle](vps_oracle/)**
- **Status**: ✅ Active
- **IP**: 130.110.251.193
- **Resources**: 2 vCPUs, 1GB RAM, 50GB storage
- **OS**: Ubuntu 24.04 Minimal
- **Purpose**: Hosting Matomo analytics server

### Planned Services

#### **[Proxy](proxy/)**
- **Status**: ⏳ Planned
- **Purpose**: Reverse proxy and load balancing
- **Stack**: Nginx

#### **[Firewall](firewall/)**
- **Status**: ⏳ Planned
- **Purpose**: Network security and protection
- **Stack**: UFW/iptables

#### **[Mail](mail/)**
- **Status**: ⏳ Planned
- **Purpose**: Email server and management
- **Stack**: Postfix/Dovecot

#### **[Sync](sync/)**
- **Status**: ⏳ Planned
- **Purpose**: File synchronization service
- **Stack**: Syncthing/Nextcloud

#### **[Drive](drive/)**
- **Status**: ⏳ Planned
- **Purpose**: Cloud storage and file management
- **Stack**: Nextcloud

#### **[VPS Google](vps_google/)**
- **Status**: ⏳ Planned
- **Purpose**: Google Cloud Platform services
- **Resources**: Billing disabler function

---

## 🛠️ Operations

### **[1.ops/](1.ops/)**
Operations scripts and management tools:
- Docker installation and configuration
- Quick reference guides
- Infrastructure automation scripts

### **[0.spec/](0.spec/)**
Project specifications and documentation:
- Constitution and principles
- Technical specifications
- Implementation plans
- Task tracking

---

## 📊 Infrastructure Overview

```
Cloud Services
│
├── Front-Cloud (Web Dashboard)
│   └── Service management interface
│
├── Analytics (Matomo)
│   ├── VPS Oracle (130.110.251.193)
│   ├── Docker Stack (Matomo + MariaDB + Nginx Proxy)
│   └── Domain: analytics.diegonmarcos.com
│
├── Proxy (Planned)
│   └── Nginx reverse proxy
│
├── Security (Planned)
│   └── Firewall + monitoring
│
└── Storage (Planned)
    ├── Drive (Nextcloud)
    └── Sync (Real-time file sync)
```

---

## 🚀 Quick Start

### Access Dashboard
Open [front-cloud/index.html](front-cloud/index.html) in a browser to access the cloud dashboard.

### Manage Analytics Server
```bash
cd analytics/matomo
./matomo-login.sh          # SSH access
./matomo-manage.sh status  # Check status
```

### Deploy New Service
1. Navigate to service directory (e.g., `cd proxy`)
2. Follow setup instructions in service README
3. Update front-cloud dashboard links if needed

---

## 🔐 Security

- All servers use SSH key authentication only
- Firewalls configured via cloud provider security lists
- SSL/TLS via Let's Encrypt (auto-renewal)
- Credentials stored locally, not in git

---

## 📖 Documentation

Each service directory contains:
- `README.md` - Service overview and quick start
- `index.html` - Web interface or status page
- Setup scripts and configuration files
- Service-specific documentation

---

**Last Updated**: 2025-11-25
