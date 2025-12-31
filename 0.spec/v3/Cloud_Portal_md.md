# Cloud Portal - Full Documentation

> **Live URL:** https://cloud.diegonmarcos.com
> **Source:** `/home/diego/Documents/Git/front-Github_io/a_Cloud/cloud/src_vanilla/`
> **Version:** 2.1
> **Updated:** 2025-12-26

---

## Table of Contents

1. [Overview](#overview)
2. [Site Structure](#site-structure)
3. [Landing Page](#landing-page)
4. [User (Products) Page](#user-products-page)
5. [Cloud Control Page](#cloud-control-page)
6. [Architecture Page](#architecture-page)
7. [Infrastructure Details](#infrastructure-details)
8. [Theme System](#theme-system)
9. [Assets & Data Sources](#assets--data-sources)

---

## Overview

Cloud Portal is a unified dashboard for managing cloud infrastructure, VPS instances, and AI services. It provides:

- **Service Catalog** - Quick access to all hosted applications
- **Infrastructure Monitoring** - Real-time VM and container status
- **Cost Tracking** - Cloud spending and AI API costs
- **Architecture Documentation** - Visual diagrams of security and infrastructure

### Technology Stack

| Component | Technology |
|-----------|------------|
| Frontend | Vanilla HTML/CSS/JS (Single-file build) |
| Styling | CSS with Glass Morphism effects |
| Hosting | GitHub Pages |
| Analytics | Matomo (self-hosted) |
| Data | JSON files (`architecture.json`, `cloud_control.json`) |

---

## Site Structure

```
Cloud Portal
├── index.html          (Landing - Splash Screen)
├── products.html       (User - Service Catalog)
├── cloud_control.html  (Cloud Control - Monitoring)
├── architecture.html   (Architecture - Diagrams)
├── error.html          (Error Page)
├── oauth-callback.html (OAuth2 Handler)
├── styles.css          (Main Stylesheet)
└── cloud_data.js       (Dynamic Data)
```

### Navigation Hierarchy

```
Level 1: Main Navigation
├── User (Products)
├── Cloud Control
└── Architecture

Level 2: Page Tabs
├── Products Page: Products | Connect | Features
├── Cloud Control: Topology | Monitor & Audit | Orchestrate | Cost | Apps
└── Architecture: Infra | Data | Security | AI

Level 3: Sub-tabs (where applicable)
├── Topology: App | Data | Containers | Security
├── Monitor: Infra | Security | Analytics | Logs
├── Cost: Infrastructure | AI Costs
└── Security: 1) Secure VPS Arch | 2) Cloud Security Arch
```

---

## Landing Page

**File:** `index.html`

### Features

- Animated background orbs (3 floating gradient circles)
- Pulsing logo with ring effects
- Gradient title "Cloud Portal"
- Loading progress bar (5 seconds)
- Skip button for immediate redirect
- Auto-redirect to `products.html`

### Animations

| Animation | Duration | Purpose |
|-----------|----------|---------|
| `float` | 8s | Background orb movement |
| `pulse-ring` | 2s | Logo ring expansion |
| `fadeInScale` | 1s | Logo appearance |
| `fadeInUp` | 1s | Title/subtitle entrance |
| `load` | 5s | Progress bar fill |

---

## User (Products) Page

**File:** `products.html`

### Level 2 Tabs

#### Products Tab (Service Catalog)

| Category | Service | URL | Status |
|----------|---------|-----|--------|
| **AI** | Chat Multi-Model | - | `dev` |
| **AI** | WebIDE (MyTerminal) | - | `dev` |
| **Inbox** | Mail & Calendar | https://diegonmarcos.github.io/mymail | `on` |
| **Inbox** | Feed | - | `dev` |
| **Object Files** | Photos | https://diegonmarcos.github.io/myphotos | `on` |
| **Object Files** | Drive & Suite | - | `dev` |
| **Media** | Music | - | `dev` |
| **Media** | Videos & Movies | - | `dev` |
| **Me** | Linktree | https://diegonmarcos.github.io/linktree | `on` |
| **Me** | Maps | - | `dev` |

#### Connect Tab (Cloud Access)

| Category | Service | URL | Status |
|----------|---------|-----|--------|
| **Cloud** | Cloud App | https://diegonmarcos.github.io/cloud | `on` |
| **Security** | VPN | - | `dev` |
| **Security** | Vault | - | `dev` |
| **Developer** | API Endpoints | /cloud/api | `dev` |
| **Developer** | MCP Tools | /cloud/mcp | `dev` |

#### Features Tab (Capabilities)

**Frontend Features:**
- Multi-page Navigation
- Theme System (3 themes)
- Category Filtering
- Responsive Design
- Single-File Build
- Offline Capable

**Backend Services:**
- Flask REST API
- Redis Cache
- SQLite / MariaDB
- Mailu SMTP/IMAP
- Photoprism Gallery
- Radicale CalDAV

### Status Tree View

Hierarchical display of cloud infrastructure:

```
Google Cloud [dev]
├── CLI: gcloud [on]
└── VM: gcp-f-micro_1 [on]
    └── Services: NPM, Authelia, Flask API

Oracle Cloud [on]
├── CLI: oci [on]
├── VM: oci-f-micro_1 [on]
│   └── Services: Mailu Mail Suite
├── VM: oci-f-micro_2 [on]
│   └── Services: Matomo Analytics
└── VM: oci-p-flex_1 [wake]
    └── Services: Photoprism, Syncthing, Radicale

Generic VPS [tbd]
└── (Future expansion)
```

---

## Cloud Control Page

**File:** `cloud_control.html`

### Level 2 Tabs

#### Topology Tab

**Level 3 Sub-tabs:**

| Tab | Content |
|-----|---------|
| App | Application services topology |
| Data | Database allocations |
| Containers | Docker container layout |
| Security | Security service configs |

#### Monitor & Audit Tab

**Level 3 Sub-tabs:**

| Tab | Content |
|-----|---------|
| Infra | VM Overview (htop-style) |
| Security | Public ports audit, security services |
| Analytics | Matomo analytics dashboard |
| Logs | Audit log viewer |

**VM Overview Table:**

| VM | CPU | RAM | Storage | Status | Actions |
|----|-----|-----|---------|--------|---------|
| OCI Flex 1 | 2 vCPU | 8 GB | 100 GB | `wake` | Start/Stop |
| OCI Micro 1 | 1 vCPU | 1 GB | 47 GB | `on` | - |
| OCI Micro 2 | 1 vCPU | 1 GB | 47 GB | `on` | - |
| GCP Micro 1 | 1 vCPU | 1 GB | 30 GB | `on` | - |

**Service Breakdown by VM:**

| Service | Domain | Port | RAM | Storage | Health |
|---------|--------|------|-----|---------|--------|
| Matomo | analytics.diegonmarcos.com | :8080 | 512MB-1GB | 3-15GB | Healthy |
| NPM | - | :80,:443,:81 | 512MB-1GB | 400MB-2GB | Healthy |
| n8n | n8n.diegonmarcos.com | :5678 | 256-512MB | 500MB-2GB | Healthy |
| Flask API | cloud.diegonmarcos.com | :5000 | 64-128MB | 50-100MB | Healthy |
| Mailu | mail.diegonmarcos.com | - | 1-2GB | 5-50GB | Dev |
| OpenVPN | - | :1194 | 64-128MB | 50-100MB | Dev |
| Gitea | git.diegonmarcos.com | :3000 | 264-544MB | 11-15GB | Dev |
| Redis | - | :6379 | 64-256MB | 100MB-1GB | Hold |

#### Orchestrate Tab

Docker container management:
- Start/Stop containers
- View container logs
- Resource allocation
- Quick actions panel

#### Cost Tab

**Level 3 Sub-tabs:**

| Tab | Content |
|-----|---------|
| Infrastructure | VM costs, provider comparison, free tier usage |
| AI Costs | API usage, token tracking, model pricing |

**Provider Cost Distribution:**

| Provider | Tier | Monthly Cost |
|----------|------|--------------|
| Oracle Cloud | Free Tier | $0 |
| Oracle Cloud | Paid (Flex) | ~$5.50/mo |
| Google Cloud | Free Tier | $0 |
| Cloudflare | Free | $0 |
| **Total** | | **~$5.50/mo** |

**Free Tier Utilization:**

| Resource | Limit | Used | % |
|----------|-------|------|---|
| OCI Compute | 2 VMs | 2 | 100% |
| OCI Storage | 200 GB | 94 GB | 47% |
| GCP Compute | 1 e2-micro | 1 | 100% |
| GCP Egress | 1 GB/mo | ~500 MB | 50% |

#### Apps Tab

Quick access to management applications:
- NPM Dashboard (proxy.diegonmarcos.com)
- Matomo Analytics (analytics.diegonmarcos.com)
- Authelia Portal (auth.diegonmarcos.com)

---

## Architecture Page

**File:** `architecture.html`

### Level 2 Tabs

#### Infra Tab

**Infrastructure Architecture v2.0**

Multi-Cloud Topology: GCP + Oracle Cloud + Cloudflare

```
                    USER
                      │
                      ▼
              ┌──────────────┐
              │  CLOUDFLARE  │
              │ DNS + CDN    │
              └──────┬───────┘
                     │
                     ▼
         ┌───────────────────────┐
         │  GOOGLE CLOUD (GCP)   │
         │  gcp-f-micro_1 FREE   │
         │  34.55.55.234         │
         │  ┌─────┬─────┬──────┐ │
         │  │ NPM │Auth │OAuth │ │
         │  │:80  │:9091│:4180 │ │
         │  └──┬──┴──┬──┴──┬───┘ │
         └─────┼─────┼─────┼─────┘
               │     │     │
    ┌──────────┼─────┼─────┼──────────┐
    │          ▼     ▼     ▼          │
    │     ORACLE CLOUD INSTANCES      │
    │                                 │
    │  ┌─────────┐ ┌─────────┐ ┌─────────────────┐
    │  │micro_1  │ │micro_2  │ │oci-p-flex_1    │
    │  │FREE     │ │FREE     │ │$5.50/mo        │
    │  │Mail     │ │Matomo   │ │8GB RAM         │
    │  │130.110..│ │129.151..│ │84.235.234.87   │
    │  └─────────┘ └─────────┘ │ ┌─────┬───────┐│
    │                          │ │Fridge│Kitchen││
    │                          │ │Apps  │C3     ││
    │                          │ └─────┴───────┘│
    │                          └─────────────────┘
    └─────────────────────────────────────────────┘
```

**VM Capacity Table:**

| Host | VM | IP | RAM | Alloc | Headroom | Services |
|------|----|----|-----|-------|----------|----------|
| GCloud | gcp-f-micro_1 | 34.55.55.234 | 1 GB | 576 MB | 42% | proxy, authelia, oauth2, api |
| Oracle | oci-f-micro_1 | 130.110.251.193 | 1 GB | 850 MB | 15% | mail (8 containers) |
| Oracle | oci-f-micro_2 | 129.151.228.66 | 1 GB | 700 MB | 30% | matomo, mariadb |
| Oracle | oci-p-flex_1 | 84.235.234.87 | 8 GB | 6.5 GB | 19% | fridge, kitchen, redis |

#### Data Tab

Data architecture and MCP tools:
- Database schema documentation
- MCP tool integrations
- Data pipelines
- Storage layout
- Backup strategies

#### Security Tab

**Security Architecture v2.1**
*Defense in Depth - OIDC Passwordless Front Gate*

##### 1) Secure VPS Architecture

Single VPS Security Model - Network Isolation & Container Hardening

**Traffic Layers:**

| Layer | Component | Description |
|-------|-----------|-------------|
| Internet | Traffic Types | HTTP/HTTPS, SSH, SMTP/IMAP |
| Cloud Firewall | OCI/GCP Rules | Ingress/Egress filtering |
| Host Firewall | UFW | Port-level control |
| Reverse Proxy | NPM | SSL termination, routing |
| Container Network | Docker | Isolated bridge networks |
| Application | Services | Per-container hardening |

**Allowed Ports:**

| Port | Protocol | Service | Source |
|------|----------|---------|--------|
| 80 | TCP | HTTP | Any |
| 443 | TCP | HTTPS | Any |
| 22 | TCP | SSH | Restricted IPs |
| 25/465/587 | TCP | SMTP | Any |
| 993 | TCP | IMAPS | Any |

##### 2) Cloud Security Architecture

Multi-Factor Authentication Flow

**Auth Stack:**

| Layer | Method | Provider |
|-------|--------|----------|
| Primary Auth | GitHub SSO | OIDC |
| 2FA | TOTP | Aegis Authenticator |
| Passkey | WebAuthn | Browser native |
| Network Auth | WireGuard VPN | Self-hosted |
| Session | Authelia Cookies | JWT |

**Auth Flow:**

```
User → GitHub SSO (OIDC)
         │
         ▼
    Authelia 2FA ──→ TOTP Code (Aegis)
         │           or
         │           Passkey (WebAuthn)
         │
         ▼
    Session Cookie
         │
         ▼
    Protected Service
```

**SSO Across Subdomains:**

All services under `*.diegonmarcos.com` share authentication:
- analytics.diegonmarcos.com
- photos.app.diegonmarcos.com
- n8n.diegonmarcos.com
- proxy.diegonmarcos.com

#### AI Tab

AI Architecture and Model Routing:
- Multi-model chat interface
- API gateway configuration
- Token usage tracking
- Cost analysis per model
- MCP tool integrations

---

## Infrastructure Details

### Virtual Machines

| VM ID | Provider | IP | RAM | Storage | Services | Mode | Cost |
|-------|----------|-----|-----|---------|----------|------|------|
| gcp-f-micro_1 | GCloud | 34.55.55.234 | 1 GB | 30 GB | NPM, Authelia, Flask API | 24/7 | $0 |
| oci-f-micro_1 | Oracle | 130.110.251.193 | 1 GB | 47 GB | Mailu Mail Suite | 24/7 | $0 |
| oci-f-micro_2 | Oracle | 129.151.228.66 | 1 GB | 47 GB | Matomo Analytics | 24/7 | $0 |
| oci-p-flex_1 | Oracle | 84.235.234.87 | 8 GB | 100 GB | Photoprism, Syncthing, Radicale | Wake-on-Demand | $5.50/mo |

### Docker Networks

| VM | Network | Subnet | Purpose |
|----|---------|--------|---------|
| oci-f-micro_1 | mail_network | 172.20.0.0/24 | Mailu containers |
| oci-f-micro_2 | matomo_network | 172.21.0.0/24 | Analytics stack |
| gcp-f-micro_1 | proxy_network | 172.23.0.0/24 | NPM + Authelia |
| oci-p-flex_1 | dev_network | 172.24.0.0/24 | Photos, Sync, Calendar |

### Active Domains

| Domain | Service | VM | SSL |
|--------|---------|-----|-----|
| cloud.diegonmarcos.com | Cloud Portal | GitHub Pages | Cloudflare |
| analytics.diegonmarcos.com | Matomo | oci-f-micro_2 | Let's Encrypt |
| mail.diegonmarcos.com | Mailu | oci-f-micro_1 | Let's Encrypt |
| proxy.diegonmarcos.com | NPM Admin | gcp-f-micro_1 | Let's Encrypt |
| auth.diegonmarcos.com | Authelia | gcp-f-micro_1 | Let's Encrypt |
| photos.app.diegonmarcos.com | Photoprism | oci-p-flex_1 | Let's Encrypt |
| sync.diegonmarcos.com | Syncthing | oci-p-flex_1 | Let's Encrypt |
| cal.diegonmarcos.com | Radicale | oci-p-flex_1 | Let's Encrypt |
| n8n.diegonmarcos.com | n8n Automation | gcp-f-micro_1 | Let's Encrypt |

---

## Theme System

Three themes with `localStorage` persistence:

### 1. Blurred (Default)

Glass morphism effects with:
- `backdrop-filter: blur(20px)`
- Semi-transparent backgrounds
- Gradient borders
- Soft shadows

### 2. Dark

High contrast mode:
- Solid dark backgrounds
- Sharp borders
- Reduced transparency
- Enhanced readability

### 3. Minimalistic

Clean, reduced UI:
- Minimal decorations
- Flat design elements
- Maximum content focus
- Reduced animations

**Theme Toggle:** Button in top-right corner cycles through themes.

---

## Status Badges

| Badge | Meaning | Color | CSS Class |
|-------|---------|-------|-----------|
| `on` | Running and accessible | Green (#10b981) | `.status-on` |
| `dev` | Under active development | Blue (#3b82f6) | `.status-dev` |
| `wake` | Wake-on-Demand (dormant) | Cyan (#06b6d4) | `.status-wake` |
| `hold` | Waiting for resources | Yellow (#f59e0b) | `.status-hold` |
| `tbd` | Planned for future | Gray (#6b7280) | `.status-tbd` |

---

## Assets & Data Sources

### Static Assets

| File | Purpose |
|------|---------|
| `styles.css` | Main stylesheet (ITCSS methodology) |
| `cloud_data.js` | Dynamic data loader |
| `/public/cloud_thumbnail_optimized.jpg` | OG social preview image |

### Data Files

| File | Content |
|------|---------|
| `architecture.json` | Infrastructure topology data |
| `cloud_control.json` | VM and service status data |

### External Dependencies

| Service | Purpose |
|---------|---------|
| Matomo Tag Manager | Analytics tracking |
| Cloudflare | DNS, CDN, DDoS protection |
| Let's Encrypt | SSL certificates |
| GitHub Pages | Static hosting |

---

## SSH Access Reference

```bash
# Google Cloud (Proxy)
gcloud compute ssh arch-1 --zone us-central1-a

# Oracle Micro 1 (Mail)
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193

# Oracle Micro 2 (Analytics)
ssh -i ~/.ssh/id_rsa ubuntu@129.151.228.66

# Oracle Flex 1 (Apps - Wake-on-Demand)
ssh -i ~/.ssh/id_rsa ubuntu@84.235.234.87
```

---

## Related Documentation

- **Cloud Spec:** `/home/diego/Documents/Git/back-System/cloud/1.ops/Cloud-spec_.md`
- **Architecture JSON:** `/home/diego/Documents/Git/back-System/cloud/1.ops/architecture.json`
- **Website Structure:** `/home/diego/Documents/Git/front-Github_io/a_Cloud/cloud/0.spec/md_files_Cloud_Portal/WEBSITE_STRUCTURE.md`

---

*Generated from Cloud Portal source files on 2025-12-26*
