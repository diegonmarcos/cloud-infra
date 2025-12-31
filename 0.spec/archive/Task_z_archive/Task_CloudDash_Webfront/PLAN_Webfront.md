# Cloud Services Dashboard - Implementation Plan

**Document:** PLAN_Webfront.md
**Status:** READY FOR IMPLEMENTATION
**Date:** 2025-12-09
**Stack:** SvelteKit 5 + SCSS

---

## Overview

Services Access Webfront for Diego's cloud infrastructure, displaying all cloud services with Cards/List view toggle, auth redirect integration, and static HTML output for GitHub Pages.

---

## 1. Data Model (TypeScript)

**File:** `src/lib/types/service.ts`

```typescript
export type ServiceStatus = 'on' | 'dev' | 'hold' | 'tbd' | 'offline';
export type AuthLevel = 'none' | 'authelia' | 'oauth2-proxy' | 'internal';
export type ServiceCategory =
  | 'terminals'
  | 'user-productivity'
  | 'user-security'
  | 'devs-cloud'
  | 'devs-security'
  | 'devs-infra';

export interface CloudService {
  id: string;
  name: string;
  displayName: string;
  description?: string;
  category: ServiceCategory;
  vmId?: string;
  vmIp?: string;
  port?: number;
  container?: string;
  icon: { type: 'svg' | 'icon-name'; data: string };
  authLevel: AuthLevel;
  urls: { gui?: string; api?: string; landing?: string };
  status: ServiceStatus;
}

export type ViewMode = 'cards' | 'list';
```

---

## 2. JSON Schema for Services

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Cloud Services Configuration",
  "type": "object",
  "required": ["version", "services"],
  "properties": {
    "version": { "type": "string" },
    "autheliaBaseUrl": { "type": "string", "default": "https://auth.diegonmarcos.com" },
    "services": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "name", "category", "urls", "status", "authLevel"],
        "properties": {
          "id": { "type": "string" },
          "name": { "type": "string" },
          "displayName": { "type": "string" },
          "category": { "type": "string" },
          "vmId": { "type": "string" },
          "vmIp": { "type": "string" },
          "port": { "type": "number" },
          "container": { "type": "string" },
          "authLevel": { "enum": ["none", "authelia", "oauth2-proxy", "internal"] },
          "urls": { "type": "object" },
          "status": { "enum": ["on", "dev", "hold", "tbd", "offline"] }
        }
      }
    }
  }
}
```

---

## 3. SvelteKit Project Structure

```
src/
├── lib/
│   ├── types/
│   │   └── service.ts
│   ├── components/
│   │   ├── ServiceCard.svelte
│   │   ├── ServiceList.svelte
│   │   ├── CategorySection.svelte
│   │   ├── ViewToggle.svelte
│   │   └── ThemeToggle.svelte
│   ├── utils/
│   │   └── auth.ts
│   └── data/
│       └── services.json
├── routes/
│   ├── +layout.svelte
│   └── +page.svelte
└── app.scss
```

---

## 4. ServiceCard Component

**File:** `src/lib/components/ServiceCard.svelte`

```svelte
<script lang="ts">
  import type { CloudService } from '$lib/types/service';
  import { buildAuthUrl } from '$lib/utils/auth';

  let { service }: { service: CloudService } = $props();
  let targetUrl = $derived(buildAuthUrl(service));
</script>

<article class="service-card" data-status={service.status}>
  <div class="card-icon">
    {#if service.icon.type === 'svg'}
      {@html service.icon.data}
    {:else}
      <span class="icon-{service.icon.data}"></span>
    {/if}
  </div>
  <h3 class="card-title">{service.displayName}</h3>
  <p class="card-description">{service.description || ''}</p>
  <div class="card-meta">
    <span class="card-status status-{service.status}">{service.status}</span>
    {#if service.authLevel !== 'none'}
      <span class="auth-badge">{service.authLevel}</span>
    {/if}
  </div>
  <a href={targetUrl} class="card-link" target="_blank" rel="noopener">Access</a>
</article>

<style lang="scss">
  @import '../../app.scss';
</style>
```

---

## 5. Auth Redirect Logic

**File:** `src/lib/utils/auth.ts`

```typescript
import type { CloudService } from '$lib/types/service';

const AUTH_CONFIG = {
  autheliaBaseUrl: 'https://auth.diegonmarcos.com'
};

export function buildAuthUrl(service: CloudService): string {
  const targetUrl = service.urls.gui || service.urls.landing || '#';

  switch (service.authLevel) {
    case 'none':
      return targetUrl;
    case 'authelia':
      return `${AUTH_CONFIG.autheliaBaseUrl}/?rd=${encodeURIComponent(targetUrl)}`;
    case 'internal':
      return '#internal-service';
    default:
      return targetUrl;
  }
}
```

---

## 6. SCSS Structure

**File:** `src/app.scss`

```scss
:root {
  --bg-page: #0a0a0a;
  --bg-card: #1a1a1a;
  --text-primary: #ffffff;
  --text-secondary: #888888;
  --border-color: #333333;
  --border-radius: 12px;
  --card-padding: 1.5rem;
  --shadow: rgba(0, 0, 0, 0.3);
  --accent-green: #22c55e;
  --accent-yellow: #eab308;
  --accent-orange: #f97316;
}

.service-card {
  background: var(--bg-card);
  border: 1px solid var(--border-color);
  border-radius: var(--border-radius);
  padding: var(--card-padding);
  transition: all 0.3s ease;

  &:hover {
    transform: translateY(-4px);
    box-shadow: 0 8px 30px var(--shadow);
  }

  &[data-status='offline'] { opacity: 0.5; pointer-events: none; }
  &[data-status='dev'] { opacity: 0.8; }
}

.card-status {
  &.status-on { color: var(--accent-green); }
  &.status-dev { color: var(--accent-yellow); }
  &.status-hold { color: var(--accent-orange); }
}

.services-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 1.5rem;
}
```

---

## 7. Services to Include

| Service       | URL                           | VM           | Container      | Auth Level | Status |
|---------------|-------------------------------|--------------|----------------|------------|--------|
| **PRODUCTS - Terminals** |
| WebTerminal   | terminal.diegonmarcos.com     | oci-p-flex_1 | terminal-app   | authelia   | tbd    |
| Jupyterlab    | jupyter.diegonmarcos.com      | oci-p-flex_1 | jupyter-app    | authelia   | tbd    |
| IDE           | ide.diegonmarcos.com          | oci-p-flex_1 | ide-app        | authelia   | tbd    |
| AI Chat       | chat.diegonmarcos.com         | oci-p-flex_1 | ai-app         | authelia   | tbd    |
| **PRODUCTS - User Productivity** |
| Mail          | mail.diegonmarcos.com         | oci-f-micro_1| mail-front     | authelia   | on     |
| Sync          | sync.diegonmarcos.com         | oci-p-flex_1 | sync-app       | authelia   | on     |
| Drive         | drive.diegonmarcos.com        | oci-p-flex_1 | drive-app      | authelia   | on     |
| Git           | git.diegonmarcos.com          | oci-p-flex_1 | git-app        | authelia   | dev    |
| Photos        | photos.diegonmarcos.com       | oci-p-flex_1 | photo-app      | authelia   | dev    |
| **PRODUCTS - User Security** |
| Vault         | vault.diegonmarcos.com        | oci-p-flex_1 | vault-app      | authelia   | on     |
| VPN           | vpn.diegonmarcos.com          | oci-p-flex_1 | vpn-app        | authelia   | tbd    |
| **KITCHEN - Devs Cloud** |
| Analytics     | analytics.diegonmarcos.com    | oci-f-micro_2| analytics-app  | authelia   | on     |
| Cloud         | cloud.diegonmarcos.com        | oci-p-flex_1 | cloud-app      | authelia   | dev    |
| n8n           | n8n.diegonmarcos.com          | oci-p-flex_1 | infra-app      | authelia   | on     |

---

## 8. Build Process

**SvelteKit static adapter for GitHub Pages:**

```bash
# svelte.config.js
import adapter from '@sveltejs/adapter-static';

export default {
  kit: {
    adapter: adapter({
      pages: 'build',
      assets: 'build',
      fallback: 'index.html'
    }),
    paths: {
      base: '/cloud'
    }
  }
};
```

**Build command:**
```bash
npm run build
```

---

## 9. Implementation Steps

1. Initialize SvelteKit 5 project with SCSS
2. Create TypeScript interfaces in `src/lib/types/`
3. Create services data file from MASTERPLAN
4. Create `auth.ts` with redirect logic
5. Create Svelte components (ServiceCard, ServiceList, CategorySection)
6. Create main page with view toggle
7. Configure static adapter for GitHub Pages
8. Test build and mobile responsiveness
9. Deploy to GitHub Pages

---

## Critical Files

- `/home/diego/Documents/Git/front-Github_io/cloud/src/lib/types/service.ts`
- `/home/diego/Documents/Git/front-Github_io/cloud/src/app.scss`
- `/home/diego/Documents/Git/front-Github_io/cloud/svelte.config.js`
- `/home/diego/Documents/Git/back-System/cloud/0.spec/MASTERPLAN.md`
