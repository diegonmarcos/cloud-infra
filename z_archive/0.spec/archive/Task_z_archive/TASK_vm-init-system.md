# TASK: Declarative VM Init System — Own Container Startup Completely

**Status**: TODO
**Created**: 2026-03-19

## Context

Docker's `restart: unless-stopped` causes all containers to start simultaneously on daemon boot. On 1GB VMs (gcp-proxy, oci-mail, oci-analytics), this thundering herd causes OOM. The current `container-init.nix` mitigates this with a hardcoded priority list but is fragile — must be manually updated when services change, and fights with Docker's own restart policy.

**Goal**: Remove Docker auto-restart entirely. Replace with a declarative per-VM init system that controls all container startup via systemd.

## Design Decisions

1. **Restart policy**: Change default from `unless-stopped` → `on-failure` in `docker.nix`
   - Containers auto-restart on crash (resilience)
   - Containers do NOT auto-start on Docker daemon boot (no thundering herd)
   - The init system exclusively controls boot-time startup order

2. **Per-VM config lives in each VM's .nix file** — same pattern as system-protection.nix, firewall.nix

3. **`build.sh ship` unchanged** — continues to `docker compose up -d` directly. The init system only controls boot-time startup.

4. **Mailu keeps `restart: always`** — mail delivery must survive everything

## Implementation

### Step 1: Change default restart policy in `_shared/docker.nix`

**File**: `a_solutions/_shared/docker.nix` line 131

```nix
# Before:
restart ? "unless-stopped",
# After:
restart ? "on-failure",
```

### Step 2: Fix raw-YAML services that hardcode restart policies

| Service | Current | Action |
|---------|---------|--------|
| hedgedoc, mattermost-bots, photoprism, photos-webhook, revealmd | `unless-stopped` | → `on-failure` |
| grist | `restart = "always"` (mkService override) | Remove override (inherit default) |
| **Mailu** | `restart: always` | **KEEP** — critical mail infra |

### Step 3: Create `vm-init.nix` module

**New file**: `b_infra/home-manager/_shared/modules/vm-init.nix`

**Replaces**: `container-init.nix`

Parameters:
```nix
{ config, pkgs, lib,
  vmName,
  ramMB,                    # determines sequential vs parallel for tier3
  staleContainers ? [],     # containers to remove (migrated away)
  staleDirs ? [],           # compose dirs to remove from /opt/containers/
  tiers ? {},               # { tier1 = [...]; tier2 = [...]; tier3 = [...]; }
}
```

Boot sequence:
```
docker.service → vm-init.service
  ├── Phase 0: Cleanup stale containers + dirs
  ├── Phase 1 (tier1): Core infra — sequential, 5s delay, wait healthy
  ├── Phase 2 (tier2): Essential services — sequential, 3s delay
  ├── Phase 3 (tier3): App services — sequential 2s on ≤1GB, parallel on >1GB
  └── Phase 4: Safety net — start any /opt/containers/* not in any tier
```

Systemd unit:
```ini
[Unit]
Description=VM Init — declarative container startup (${vmName})
After=docker.service network-online.target wg-quick@wg0.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/scripts/vm-init.sh
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
```

### Step 4: Update all VM .nix files

**gcp-proxy.nix** (1GB):
```nix
(import ./modules/vm-init.nix {
  inherit config pkgs lib;
  vmName = "gcp-proxy"; ramMB = 1024;
  staleContainers = [ "syslog-central" "siem-api" "alerts-api" "dozzle" "fluent-bit" ];
  staleDirs = [ "sauron-central" "alerts-api" "dozzle" "fluent-bit" ];
  tiers = {
    tier1 = [ "hickory-dns" "caddy" ];
    tier2 = [ "authelia" "redis" "postlite" ];
    tier3 = [ "vaultwarden" "ntfy" ];
  };
})
```

**oci-mail.nix** (1GB):
```nix
(import ./modules/vm-init.nix {
  inherit config pkgs lib;
  vmName = "oci-mail"; ramMB = 1024;
  tiers = {
    tier1 = [ "mailu" ];
    tier2 = [ "smtp-proxy" "syslog-forwarder" ];
    tier3 = [ "dagu" ];
  };
})
```

**oci-analytics.nix** (1GB):
```nix
(import ./modules/vm-init.nix {
  inherit config pkgs lib;
  vmName = "oci-analytics"; ramMB = 1024;
  tiers = {
    tier1 = [ "fluent-bit" "sauron-forwarder" ];
    tier2 = [ "sauron-central" "alerts-api" ];
    tier3 = [ "matomo" "umami" "dozzle" ];
  };
})
```

**oci-apps.nix** (24GB — parallel tier3):
```nix
(import ./modules/vm-init.nix {
  inherit config pkgs lib;
  vmName = "oci-apps"; ramMB = 24576;
  tiers = {
    tier1 = [ "c3-infra-mcp-api" "orchestrator" ];
    tier2 = [ "lgtm" "crawlee-cloud" ];
    tier3 = [];  # Everything else auto-discovered, started in parallel
  };
})
```

**gcp-t4.nix** + **oci-apps-2.nix**:
```nix
(import ./modules/vm-init.nix {
  inherit config pkgs lib;
  vmName = "gcp-t4"; ramMB = 15360;
  tiers = { tier1 = [ "ollama" ]; };
})
```

### Step 5: Delete `container-init.nix`

Remove after vm-init.nix is deployed and verified on all VMs.

## Critical Files

| File | Action |
|------|--------|
| `a_solutions/_shared/docker.nix` | Change default restart: `unless-stopped` → `on-failure` |
| `b_infra/home-manager/_shared/modules/vm-init.nix` | **CREATE** — new declarative init module |
| `b_infra/home-manager/_shared/modules/container-init.nix` | **DELETE** after migration |
| `b_infra/home-manager/*/src/*.nix` (all 6 VMs) | Replace container-init with vm-init |
| Raw YAML flakes (hedgedoc, mattermost-bots, etc.) | Fix restart policy |

## Rollout

1. Change docker.nix default + fix raw-YAML services
2. Create vm-init.nix + update gcp-proxy.nix (first VM)
3. Commit + push → GHA deploys to gcp-proxy
4. Test: reboot gcp-proxy, verify sequential startup, no OOM
5. Roll out to oci-mail, oci-analytics, oci-apps
6. Delete container-init.nix

## Verification

- Reboot each VM → containers start in declared order
- `journalctl -u vm-init` shows tier progression
- No OOM on 1GB VMs during boot
- `build.sh ship` still works (direct compose up)
- Undeclared services in /opt/containers/ still start (safety net)
