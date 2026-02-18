# Architecture Specs System - Implementation Plan

**Document:** PLAN_ArchSpecs.md
**Status:** READY FOR IMPLEMENTATION
**Date:** 2025-12-09

---

## Overview

Per-service specification system providing machine-readable JSON specs, human-readable markdown docs, central manifest, and architecture visualization webfront.

---

## 1. Directory Structure

```
/home/diego/Documents/Git/back-System/cloud/0.spec/Task_ArchSpecs/
├── schema/
│   ├── service-spec.schema.json
│   └── manifest.schema.json
├── services/
│   ├── products/
│   │   ├── terminals/
│   │   │   ├── terminal.spec.json
│   │   │   ├── jupyter.spec.json
│   │   │   ├── ide.spec.json
│   │   │   └── ai-chat.spec.json
│   │   ├── user-productivity/
│   │   │   ├── mail.spec.json
│   │   │   ├── sync.spec.json
│   │   │   ├── drive.spec.json
│   │   │   ├── git.spec.json
│   │   │   └── photos.spec.json
│   │   └── user-security/
│   │       ├── vault.spec.json
│   │       └── vpn.spec.json
│   └── kitchen/
│       ├── devs-cloud/
│       │   ├── analytics.spec.json
│       │   ├── cloud.spec.json
│       │   ├── n8n-infra.spec.json
│       │   └── n8n-ai.spec.json
│       ├── devs-security/
│       │   ├── proxy.spec.json
│       │   ├── oauth2.spec.json
│       │   └── authelia.spec.json
│       └── devs-infra/
│           ├── api.spec.json
│           └── cache.spec.json
├── templates/
│   └── service.md.j2
├── build/
│   └── build_specs.py
├── output/
│   ├── manifest.json
│   ├── services-combined.json
│   └── docs/
└── README.md
```

---

## 2. JSON Schema (ServiceSpec)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ServiceSpec",
  "type": "object",
  "required": ["id", "name", "version", "vmHost", "status", "containers"],
  "properties": {
    "id": { "type": "string", "pattern": "^[a-z0-9-]+$" },
    "name": { "type": "string" },
    "displayName": { "type": "string" },
    "description": { "type": "string" },
    "version": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "category": {
      "enum": [
        "terminals",
        "user-productivity",
        "user-security",
        "devs-cloud",
        "devs-security",
        "devs-infra"
      ]
    },
    "section": { "enum": ["products", "kitchen"] },
    "vmHost": {
      "type": "object",
      "properties": {
        "vmId": { "type": "string" },
        "vmName": { "type": "string" },
        "provider": { "enum": ["oracle", "gcloud"] },
        "ip": { "type": "string" }
      }
    },
    "containers": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": { "type": "string" },
          "purpose": { "type": "string" },
          "port": { "type": "integer" },
          "stack": { "type": "string" }
        }
      }
    },
    "urls": {
      "type": "object",
      "properties": {
        "public": { "type": "string" },
        "admin": { "type": "string" },
        "health": { "type": "string" }
      }
    },
    "dependencies": {
      "type": "object",
      "properties": {
        "services": { "type": "array" },
        "databases": { "type": "array" },
        "proxy": { "type": "string" }
      }
    },
    "auth": {
      "type": "object",
      "properties": {
        "method": { "enum": ["none", "authelia-2fa", "oauth2", "api-key"] },
        "required": { "type": "boolean" }
      }
    },
    "health": {
      "type": "object",
      "properties": {
        "endpoint": { "type": "string" },
        "method": { "enum": ["GET", "HEAD", "TCP"] },
        "expectedStatus": { "type": "integer" }
      }
    },
    "docker": {
      "type": "object",
      "properties": {
        "composePath": { "type": "string" }
      }
    },
    "status": { "enum": ["on", "dev", "hold", "tbd"] }
  }
}
```

---

## 3. Example Service Spec

**File:** `services/kitchen/devs-cloud/analytics.spec.json`

```json
{
  "id": "analytics",
  "name": "Analytics",
  "displayName": "Matomo Analytics",
  "description": "Self-hosted web analytics platform",
  "version": "1.0.0",
  "section": "kitchen",
  "category": "devs-cloud",
  "vmHost": {
    "vmId": "oci-f-micro_2",
    "vmName": "OCI Free Micro 2",
    "provider": "oracle",
    "ip": "129.151.228.66"
  },
  "containers": [
    { "name": "analytics-front", "purpose": "Login + stats display", "port": null, "stack": "Matomo (built-in)" },
    { "name": "analytics-app", "purpose": "Analytics engine", "port": 8080, "stack": "Matomo (PHP-FPM)" },
    { "name": "analytics-db0", "purpose": "Visits, events, reports", "port": null, "stack": "SQL:MariaDB" }
  ],
  "urls": {
    "public": "https://analytics.diegonmarcos.com",
    "health": "/matomo.php"
  },
  "dependencies": {
    "proxy": "proxy-app"
  },
  "auth": {
    "method": "authelia-2fa",
    "required": true
  },
  "health": {
    "endpoint": "/matomo.php",
    "method": "GET",
    "expectedStatus": 200
  },
  "docker": {
    "composePath": "vps_oracle/vm-oci-f-micro_2/2.app/analytics-app/docker-compose.yml"
  },
  "status": "on"
}
```

---

## 4. Manifest Schema

```json
{
  "version": "1.0.0",
  "generated": "2025-12-09T14:30:00Z",
  "sections": {
    "products": {
      "name": "Products",
      "categories": ["terminals", "user-productivity", "user-security"]
    },
    "kitchen": {
      "name": "Kitchen",
      "categories": ["devs-cloud", "devs-security", "devs-infra"]
    }
  },
  "categories": {
    "terminals": {
      "name": "Terminals",
      "section": "products",
      "services": ["terminal", "jupyter", "ide", "ai-chat"]
    },
    "devs-cloud": {
      "name": "Devs Cloud Dashboard",
      "section": "kitchen",
      "services": ["analytics", "cloud", "n8n-infra", "n8n-ai"]
    }
  },
  "services": {
    "analytics": {
      "specFile": "services/kitchen/devs-cloud/analytics.spec.json",
      "status": "on",
      "url": "https://analytics.diegonmarcos.com"
    }
  },
  "vms": {
    "oci-f-micro_2": {
      "provider": "oracle",
      "ip": "129.151.228.66",
      "services": ["analytics"]
    },
    "oci-p-flex_1": {
      "provider": "oracle",
      "ip": "84.235.234.87",
      "services": ["terminal", "jupyter", "ide", "ai-chat", "sync", "drive", "git", "photos", "vault", "vpn", "cloud", "n8n-infra", "n8n-ai", "api", "cache"]
    },
    "oci-f-micro_1": {
      "provider": "oracle",
      "ip": "130.110.251.193",
      "services": ["mail"]
    },
    "gcp-f-micro_1": {
      "provider": "gcloud",
      "ip": "34.55.55.234",
      "services": ["proxy", "authelia", "oauth2"]
    }
  },
  "stats": {
    "totalServices": 18,
    "activeServices": 8
  }
}
```

---

## 5. Markdown Template

**File:** `templates/service.md.j2`

```jinja2
# {{ spec.displayName or spec.name }}

> **Service ID**: `{{ spec.id }}`
> **Status**: {{ spec.status | upper }}
> **Section**: {{ spec.section | title }} / {{ spec.category | replace('-', ' ') | title }}

## Overview
{{ spec.description or 'No description provided.' }}

## Host Information
| Property | Value |
|----------|-------|
| **VM** | {{ spec.vmHost.vmName }} (`{{ spec.vmHost.vmId }}`) |
| **Provider** | {{ spec.vmHost.provider | title }} |
| **IP** | `{{ spec.vmHost.ip }}` |

## Containers
| Container | Purpose | Port | Stack |
|-----------|---------|------|-------|
{% for c in spec.containers %}
| `{{ c.name }}` | {{ c.purpose }} | {{ c.port or '-' }} | {{ c.stack }} |
{% endfor %}

## URLs
| Endpoint | URL |
|----------|-----|
| **Public** | [{{ spec.urls.public }}]({{ spec.urls.public }}) |

## Quick Commands
```bash
# SSH to VM
ssh ubuntu@{{ spec.vmHost.ip }}

# View container logs
{% for c in spec.containers %}
docker logs {{ c.name }}
{% endfor %}

# Docker compose
cd {{ spec.docker.composePath | dirname }}
docker compose logs -f
```
```

---

## 6. Build Script

**File:** `build/build_specs.py`

```python
#!/usr/bin/env python3
"""Build Architecture Specs - combines specs into manifest and docs."""

import json
from pathlib import Path
from datetime import datetime
from jinja2 import Template

SPECS_ROOT = Path(__file__).parent.parent
SERVICES_DIR = SPECS_ROOT / "services"
TEMPLATES_DIR = SPECS_ROOT / "templates"
OUTPUT_DIR = SPECS_ROOT / "output"

def load_all_specs():
    specs = {}
    for spec_file in SERVICES_DIR.rglob("*.spec.json"):
        with open(spec_file) as f:
            spec = json.load(f)
            spec['_file'] = str(spec_file.relative_to(SPECS_ROOT))
            specs[spec['id']] = spec
    return specs

def generate_manifest(specs):
    # Group by section and category
    sections = {'products': [], 'kitchen': []}
    categories = {}
    vms = {}

    for id, spec in specs.items():
        section = spec.get('section', 'products')
        category = spec.get('category', 'unknown')
        vm_id = spec.get('vmHost', {}).get('vmId', 'unknown')

        if category not in categories:
            categories[category] = {'name': category.replace('-', ' ').title(), 'section': section, 'services': []}
        categories[category]['services'].append(id)

        if vm_id not in vms:
            vm_host = spec.get('vmHost', {})
            vms[vm_id] = {
                'provider': vm_host.get('provider', 'unknown'),
                'ip': vm_host.get('ip', ''),
                'services': []
            }
        vms[vm_id]['services'].append(id)

    return {
        "version": "1.0.0",
        "generated": datetime.utcnow().isoformat() + "Z",
        "categories": categories,
        "services": {id: {"specFile": s['_file'], "status": s["status"], "url": s.get('urls', {}).get('public', '')} for id, s in specs.items()},
        "vms": vms,
        "stats": {"totalServices": len(specs), "activeServices": sum(1 for s in specs.values() if s['status'] == 'on')}
    }

def generate_docs(specs, template_path):
    with open(template_path) as f:
        template = Template(f.read())

    docs_dir = OUTPUT_DIR / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)

    for id, spec in specs.items():
        doc = template.render(spec=spec)
        with open(docs_dir / f"{id}.md", 'w') as f:
            f.write(doc)

def main():
    specs = load_all_specs()
    manifest = generate_manifest(specs)

    OUTPUT_DIR.mkdir(exist_ok=True)

    # Write manifest
    with open(OUTPUT_DIR / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    # Write combined specs
    with open(OUTPUT_DIR / "services-combined.json", "w") as f:
        json.dump({id: {k: v for k, v in s.items() if not k.startswith('_')} for id, s in specs.items()}, f, indent=2)

    # Generate markdown docs
    template_path = TEMPLATES_DIR / "service.md.j2"
    if template_path.exists():
        generate_docs(specs, template_path)

    print(f"Built manifest with {len(specs)} services ({manifest['stats']['activeServices']} active)")

if __name__ == "__main__":
    main()
```

---

## 7. Implementation Steps

1. Create directory structure (products/kitchen organization)
2. Write JSON schemas with container array support
3. Create spec files for each service from MASTERPLAN
4. Write Jinja2 markdown template
5. Create build script with manifest + docs generation
6. Run build and verify outputs
7. Create architecture webfront (Mermaid diagrams)
8. Integrate with SvelteKit cloud dashboard

---

## Critical Files

- `/home/diego/Documents/Git/back-System/cloud/0.spec/MASTERPLAN.md` - Source of truth
- `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_dash.json` - API data source
- `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_dash.py` - Flask API
