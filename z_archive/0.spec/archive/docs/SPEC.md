# Cloud Infrastructure Specification

> **Single Source of Truth** - All infrastructure data is defined in `cloud-infrastructure.json`

---

## Quick Links

| Resource | URL |
|----------|-----|
| **Matomo Analytics** | https://analytics.diegonmarcos.com |
| **Syncthing** | https://sync.diegonmarcos.com |
| **n8n Automation** | https://n8n.diegonmarcos.com |
| **Oracle Console** | https://cloud.oracle.com |
| **Google Console** | https://console.cloud.google.com |

---

## 1. Infrastructure Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CLOUD INFRASTRUCTURE                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    ORACLE CLOUD (Always Free)                │    │
│  │                                                              │    │
│  │  ┌─────────────────────┐    ┌─────────────────────┐         │    │
│  │  │   web-server-1      │    │  services-server-1  │         │    │
│  │  │   130.110.251.193   │    │  129.151.228.66     │         │    │
│  │  │                     │    │                     │         │    │
│  │  │  ├─ Matomo         │    │  ├─ n8n             │         │    │
│  │  │  ├─ Syncthing      │    │  └─ NPM             │         │    │
│  │  │  └─ NPM            │    │                     │         │    │
│  │  │                     │    │  Status: ✅ Active  │         │    │
│  │  │  Status: ✅ Active  │    └─────────────────────┘         │    │
│  │  └─────────────────────┘                                    │    │
│  │                                                              │    │
│  │  ┌─────────────────────┐                                    │    │
│  │  │   arm-server        │    (VM.Standard.A1.Flex)           │    │
│  │  │   IP: pending       │    4 OCPU • 24GB RAM • 200GB       │    │
│  │  │                     │                                    │    │
│  │  │  ├─ Mail Server    │    Status: ⏳ Capacity Waitlist    │    │
│  │  │  ├─ Nextcloud      │                                    │    │
│  │  │  └─ Terminal       │                                    │    │
│  │  └─────────────────────┘                                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    GOOGLE CLOUD (Free Tier)                  │    │
│  │                                                              │    │
│  │  ┌─────────────────────┐                                    │    │
│  │  │   arch-1            │    (e2-micro)                      │    │
│  │  │   IP: pending       │    0.25-2 vCPU • 1GB               │    │
│  │  │                     │                                    │    │
│  │  │  Status: ⏳ Pending  │                                    │    │
│  │  └─────────────────────┘                                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Active Services

### 2.1 Matomo Analytics
| Property | Value |
|----------|-------|
| **VM** | web-server-1 |
| **Domain** | analytics.diegonmarcos.com |
| **Internal Port** | 8080 |
| **Technology** | matomo:fpm-alpine + mariadb:11.4 |
| **Status** | ✅ Active |

### 2.2 Syncthing
| Property | Value |
|----------|-------|
| **VM** | web-server-1 |
| **Domain** | sync.diegonmarcos.com |
| **Internal Port** | 8384 |
| **Sync Port** | 22000/TCP, 21027/UDP |
| **Technology** | syncthing/syncthing |
| **Status** | ✅ Active |

### 2.3 n8n Automation
| Property | Value |
|----------|-------|
| **VM** | services-server-1 |
| **Domain** | n8n.diegonmarcos.com |
| **Internal Port** | 5678 |
| **Technology** | n8nio/n8n |
| **Status** | ✅ Active |

---

## 3. SSH Access

```bash
# Web Server 1 (Matomo, Syncthing)
ssh -i ~/.ssh/matomo_key ubuntu@130.110.251.193

# Services Server 1 (n8n)
ssh -i ~/.ssh/matomo_key ubuntu@129.151.228.66

# Docker commands (after SSH)
sudo docker ps
sudo docker logs --tail 100 matomo-app
sudo docker exec -it matomo-app bash
```

---

## 4. Network & Ports

### External Ports (Internet-facing)
| Port | Protocol | Service | VM |
|------|----------|---------|-----|
| 22 | TCP | SSH | All |
| 80 | TCP | HTTP (→ HTTPS) | All |
| 443 | TCP | HTTPS | All |
| 81 | TCP | NPM Admin | web-server-1, services-server-1 |
| 22000 | TCP | Syncthing Sync | web-server-1 |
| 21027 | UDP | Syncthing Discovery | web-server-1 |

### Internal Ports (localhost only, proxied via NPM)
| Port | Service | VM |
|------|---------|-----|
| 8080 | Matomo | web-server-1 |
| 8384 | Syncthing GUI | web-server-1 |
| 5678 | n8n | services-server-1 |

---

## 5. Future Services (Planned for arm-server)

| Service | Domain | Status |
|---------|--------|--------|
| Mail Server | mail.diegonmarcos.com | Development |
| Nextcloud | cloud.diegonmarcos.com | Planned |
| OS Terminal | - | Development |
| DevOps Dashboard | - | Development |

---

## 6. Data Files

| File | Purpose |
|------|---------|
| `cloud-infrastructure.json` | **Primary data source** - All infrastructure data |
| `SPEC.md` | Human-readable documentation (this file) |
| `HANDOFF.md` | Quick reference for web developers |
| `VPS_ARCHITECTURE_SPEC.md` | Detailed security & architecture design |
| `spec_infra.md` | Mermaid diagrams for visualization |

---

## 7. Front-End Integration

The front-end dashboard at `/front-cloud/` should read from `cloud-infrastructure.json` for:

- **Services list** → `services` object
- **VM cards** → `virtualMachines` object
- **Provider cards** → `providers` object
- **URLs & commands** → Each service/VM contains its URLs
- **Status indicators** → `status` field on each entity

### TypeScript Types (suggested)

```typescript
interface CloudInfrastructure {
  providers: Record<string, Provider>;
  virtualMachines: Record<string, VirtualMachine>;
  services: Record<string, Service>;
  domains: DomainConfig;
  firewallRules: Record<string, FirewallRule[]>;
  dockerNetworks: Record<string, DockerNetwork>;
  quickCommands: QuickCommands;
}
```

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-01 | Consolidated CSV files into single JSON; Created SPEC.md |
| 2025-11-27 | Added services-server-1 with n8n |
| 2025-11-26 | Initial infrastructure documentation |

---

**Last Updated**: 2025-12-01
**Maintainer**: Diego Nepomuceno Marcos
