# Cloud Infrastructure Handoff

> **For Front-End Developers**: Use `cloud-infrastructure.json` as the data source.
> **For Cloud Engineers**: Update `cloud-infrastructure.json` and regenerate documentation.

---

## Data Source

```
0.spec/
├── cloud-infrastructure.json   ← PRIMARY DATA SOURCE
├── SPEC.md                     ← Human-readable documentation
├── HANDOFF.md                  ← This file (quick reference)
├── VPS_ARCHITECTURE_SPEC.md    ← Detailed security architecture
├── spec_infra.md               ← Mermaid diagrams
└── archive/
    └── csv/                    ← Legacy CSV files (deprecated)
```

---

## JSON Structure Overview

```json
{
  "providers": {
    "oracle": { /* Console URL, CLI commands */ },
    "gcloud": { /* Console URL, CLI commands */ }
  },
  "virtualMachines": {
    "web-server-1": { /* IP, SSH, services, ports */ },
    "services-server-1": { /* IP, SSH, services, ports */ },
    "arm-server": { /* Pending - future main server */ },
    "arch-1": { /* Pending - GCloud dev VM */ }
  },
  "services": {
    "matomo": { /* URLs, ports, docker config */ },
    "syncthing": { /* URLs, ports, docker config */ },
    "n8n": { /* URLs, ports, docker config */ },
    "mail": { /* Planned */ },
    "nextcloud": { /* Planned */ }
  },
  "domains": { /* DNS mappings */ },
  "firewallRules": { /* Per-VM port rules */ },
  "quickCommands": { /* SSH, Docker commands */ }
}
```

---

## Front-End Card Mapping

### Services Section
| Card | JSON Path | Click Action |
|------|-----------|--------------|
| Matomo Analytics | `services.matomo` | Open `urls.gui` |
| Syncthing | `services.syncthing` | Open `urls.gui` |
| n8n Automation | `services.n8n` | Open `urls.gui` |

### VPS Providers Section
| Card | JSON Path | Click Action |
|------|-----------|--------------|
| Oracle Cloud | `providers.oracle` | Open `consoleUrl` |
| Google Cloud | `providers.gcloud` | Open `consoleUrl` |

### Virtual Machines Section
| Card | JSON Path | Click Action |
|------|-----------|--------------|
| web-server-1 | `virtualMachines.web-server-1` | Show SSH modal |
| services-server-1 | `virtualMachines.services-server-1` | Show SSH modal |
| arm-server | `virtualMachines.arm-server` | Show "pending" |
| arch-1 | `virtualMachines.arch-1` | Show "pending" |

### Under Development Section
| Card | JSON Path | Status |
|------|-----------|--------|
| Mail Server | `services.mail` | `development` |
| Nextcloud | `services.nextcloud` | `planned` |
| OS Terminal | `services.terminal` | `development` |
| Dashboard | `services.dashboard` | `development` |

---

## Status Values

| Status | Display | Card Style |
|--------|---------|------------|
| `active` | ✅ Online | Green indicator |
| `pending` | ⏳ Pending | Yellow indicator |
| `development` | 🔧 In Development | Blue indicator |
| `planned` | 📋 Planned | Gray indicator |
| `offline` | ❌ Offline | Red indicator |

---

## Quick Access URLs

### Active Services
- **Matomo**: https://analytics.diegonmarcos.com
- **Syncthing**: https://sync.diegonmarcos.com
- **n8n**: https://n8n.diegonmarcos.com

### Proxy Admin Panels
- **web-server-1 NPM**: http://130.110.251.193:81
- **services-server-1 NPM**: http://129.151.228.66:81

### Cloud Consoles
- **Oracle**: https://cloud.oracle.com
- **Google**: https://console.cloud.google.com

---

## SSH Commands (for copy buttons)

```bash
# web-server-1
ssh -i ~/.ssh/matomo_key ubuntu@130.110.251.193

# services-server-1
ssh -i ~/.ssh/matomo_key ubuntu@129.151.228.66
```

---

## Architecture Diagrams

### High-Level View

```
┌─────────────────────────────────────────────────────────────────┐
│                         INTERNET                                 │
└─────────────────────────────┬───────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│     web-server-1        │     │   services-server-1     │
│   130.110.251.193       │     │   129.151.228.66        │
├─────────────────────────┤     ├─────────────────────────┤
│ NPM (:81)               │     │ NPM (:81)               │
│   ├── :443 → Matomo     │     │   └── :443 → n8n        │
│   └── :443 → Syncthing  │     │                         │
│                         │     │                         │
│ analytics.diegonmarcos  │     │ n8n.diegonmarcos.com    │
│ sync.diegonmarcos.com   │     │                         │
└─────────────────────────┘     └─────────────────────────┘
```

### Service Flow

```
User Request
     │
     ▼
┌─────────────┐
│    DNS      │ analytics.diegonmarcos.com → 130.110.251.193
└─────┬───────┘
      │
      ▼
┌─────────────┐
│ NPM (:443)  │ SSL Termination + Routing
└─────┬───────┘
      │
      ▼
┌─────────────┐
│ Matomo      │ localhost:8080 (Docker)
│ (:8080)     │
└─────────────┘
```

---

## TypeScript Integration

```typescript
// Load infrastructure data
const infra = await fetch('/0.spec/cloud-infrastructure.json').then(r => r.json());

// Get service URL
const matomoUrl = infra.services.matomo.urls.gui;

// Get SSH command
const sshCmd = infra.virtualMachines['web-server-1'].ssh.command;

// Check status
const isActive = infra.services.matomo.status === 'active';
```

---

## Changelog

| Date | Change | By |
|------|--------|-----|
| 2025-12-01 | Migrated to JSON data source, deprecated CSV | Cloud Engineer |
| 2025-11-27 | Added services-server-1 with n8n | Cloud Engineer |
| 2025-11-26 | Initial handoff structure | Cloud Engineer |
