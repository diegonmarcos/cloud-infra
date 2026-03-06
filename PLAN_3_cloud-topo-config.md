# PLAN: Cloud Topology + Configs Consolidation

## Problem

1. C3-API on oci-apps is half-blind — `~/git/` repos not cloned, so `read_file`, `search_repos`, drift detection silently fail
2. No consolidated declarative configs exist (routes, ACL, topics, peers, mailboxes)
3. `gen-config.ts` lives in `cloud/tools/` — C3-API should own the engines
4. `config.json` is a generic name mixing infrastructure topology with service metadata
5. `build.sh` has no dependency engine — fails silently on VMs missing node/tsx/sops/etc.

## Output Files

| File | Content |
|------|---------|
| `cloud-topology.json` | Infrastructure layout: VMs, VPSs, WireGuard mesh, networks, DNS, containers, ports, firewall |
| `cloud-configs.json` | Per-service configs split into `infra` (C3/ops tools) and `apps` (user-facing services) |
| `cloud-topology.md` | Human-readable tables of all topology data |
| `cloud-configs.md` | Human-readable tables of all per-service configs |

Replaces: `config.json`, `config.md`, `tools/config.md.njk`, `tools/gen-config.ts`

---

## Architecture

### C3-API owns the engines

Engines move from `cloud/tools/` into `mcp-api-c3/src/engines/`.

```
mcp-api-c3/src/engines/
  gen-topology.ts              cloud-topology.json + cloud-topology.md
  gen-configs.ts               cloud-configs.json + cloud-configs.md
  templates/
    cloud-topology.md.njk      VM tables, network tables, container tables
    cloud-configs.md.njk       per-service config tables
  parsers/
    build-json.ts              service name, category, domain, deploy host
    compose.ts                 containers, ports, networks, volumes, healthchecks
    ssh-config.ts              VM aliases, WG IPs (non-sensitive only)
    caddyfile.ts               domain > upstream:port, auth type
    authelia.ts                ACL rules, OIDC clients
    wireguard.ts               mesh peers from home-manager nix
    dns.ts                     hickory-dns zones/records
    ntfy.ts                    topics, users, auth config
    mailu.ts                   domains, mailboxes, relay
```

### `cloud/build.sh config` runs engines locally

Direct filesystem execution. No HTTP overhead.

```bash
cmd_config() {
    ENGINE_DIR="$SOLUTIONS_DIR/mcp-api-c3/src"
    [ -d "$ENGINE_DIR/node_modules" ] || (cd "$ENGINE_DIR" && npm install --silent)
    node --import tsx "$ENGINE_DIR/engines/gen-topology.ts"
    node --import tsx "$ENGINE_DIR/engines/gen-configs.ts"
}
```

API routes (`GET /topology`, `GET /configs`) exist for remote consumers only — MCP clients, dashboards, agents without repo access.

### C3-API container clones repos (read-only)

```bash
for repo in cloud unix vault front; do
  dir="/app/repos/$repo"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --all && git -C "$dir" reset --hard origin/main
  else
    git clone --depth 1 --single-branch --branch main \
      git@github.com:diegonmarcos/$repo.git "$dir"
  fi
done
exec node dist/index.js
```

- Read-only clones at `/app/repos/{cloud,unix,vault,front}`
- Force-pull (`fetch --all && reset --hard`) — no merge conflicts ever
- `reload_config` MCP tool triggers re-pull + re-generate
- `paths.ts`: `GIT_BASE = process.env.GIT_BASE ?? "/app/repos"` (container) or `~/git` (local)

### Dependency engine in `build.sh`

`build.sh` runs on ANY VM. Checks all deps at startup, reports all missing at once, offers to install.

```bash
REQUIRED_SYSTEM="node git ssh jq sops"
REQUIRED_NODE="tsx yaml nunjucks"

check_deps() {
    missing_sys=""
    missing_node=""

    for tool in $REQUIRED_SYSTEM; do
        command -v "$tool" >/dev/null 2>&1 || missing_sys="$missing_sys $tool"
    done

    if command -v node >/dev/null 2>&1; then
        engine_dir="$SOLUTIONS_DIR/mcp-api-c3/src"
        for pkg in $REQUIRED_NODE; do
            NODE_PATH="$engine_dir/node_modules" node -e "require('$pkg')" 2>/dev/null \
                || missing_node="$missing_node $pkg"
        done
    fi

    [ -z "$missing_sys" ] && [ -z "$missing_node" ] && return 0

    echo ""
    echo "============================================"
    echo "  MISSING DEPENDENCIES"
    echo "============================================"
    [ -n "$missing_sys" ]  && echo "  System:  $missing_sys"
    [ -n "$missing_node" ] && echo "  Node:    $missing_node"
    echo ""

    if command -v nix-env >/dev/null 2>&1; then
        sys_cmd="nix-env -iA$(echo "$missing_sys" | sed 's/ / nixpkgs./g; s/^/ nixpkgs./')"
    elif command -v apt-get >/dev/null 2>&1; then
        sys_cmd="sudo apt-get install -y$missing_sys"
    else
        echo "  No supported package manager (nix/apt). Install manually:"
        echo "   $missing_sys $missing_node"
        exit 1
    fi

    node_cmd=""
    [ -n "$missing_node" ] && node_cmd="(cd $SOLUTIONS_DIR/mcp-api-c3/src && npm install)"

    printf "  Install all missing deps? [y/N] "
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        [ -n "$missing_sys" ] && eval "$sys_cmd"
        [ -n "$node_cmd" ] && eval "$node_cmd"
        check_deps  # re-verify
    else
        echo "  Aborting. Install manually:"
        [ -n "$missing_sys" ] && echo "    $sys_cmd"
        [ -n "$node_cmd" ]   && echo "    $node_cmd"
        exit 1
    fi
}

# Called once at build.sh startup
check_deps
```

---

## Data Schemas

### `cloud-topology.json`

```jsonc
{
  "vms": {
    "gcp-E2-f_0": {
      "alias": "gcp-proxy",
      "ip": "35.226.147.64",
      "wg_ip": "10.0.0.1",
      "user": "diego",
      "method": "gcloud",
      "description": "...",
      "containers": ["caddy", "authelia", "introspect-proxy", "ntfy"],
      "ports": ["80:80", "443:443", "53:53"],
      "networks": ["npm_default"]
    }
  },
  "vpss": {
    "oci": { "provider": "Oracle Cloud", "tier": "free", "instances": ["oci-E2-f_0", "oci-A1-f_0"] }
  },
  "wireguard": {
    "peers": [
      { "name": "gcp-proxy", "wg_ip": "10.0.0.1", "endpoint": "35.226.147.64:51820" },
      { "name": "oci-apps", "wg_ip": "10.0.0.6", "endpoint": "82.70.229.129:51820" }
    ]
  },
  "dns": {
    "zones": [{ "name": "internal", "records": [{ "name": "proxy", "type": "A", "value": "10.0.0.1" }] }]
  },
  "services": {
    "caddy": {
      "category": "sec",
      "vm": "gcp-E2-f_0",
      "domain": "proxy.diegonmarcos.com",
      "containers": ["caddy", "introspect-proxy"],
      "ports": ["80:80", "443:443"],
      "networks": ["npm_default"],
      "description": "Caddy reverse proxy"
    }
  }
}
```

### `cloud-configs.json`

```jsonc
{
  "infra": {
    "caddy": {
      "routes": [
        { "domain": "rss.diegonmarcos.com", "upstream": "ntfy:80", "auth": "3-tier" },
        { "domain": "mail.diegonmarcos.com", "upstream": "10.0.0.3:8444", "auth": "authelia+bearer", "tls_skip": true },
        { "domain": "analytics.diegonmarcos.com", "upstream": "10.0.0.4:8080", "auth": "authelia+bearer",
          "public_paths": ["/matomo.js", "/matomo.php", "/js/*"] }
      ]
    },
    "authelia": {
      "acl": [
        { "domain": "vault.*", "policy": "two_factor" },
        { "domain": "*.diegonmarcos.com", "policy": "one_factor" }
      ]
    },
    "hickory-dns": {
      "zones": [{ "name": "internal", "records": ["proxy.internal > 10.0.0.1"] }]
    }
  },
  "apps": {
    "ntfy": {
      "topics": ["syslog", "github-releases", "alerts", "health", "backups"],
      "users": ["admin", "diego"],
      "enable_login": true,
      "auth_default_access": "read-write"
    },
    "mailu": {
      "domain": "diegonmarcos.com",
      "mailboxes": ["me@", "no-reply@"],
      "relay": "smtp.email.eu-marseille-1.oci.oraclecloud.com:587"
    },
    "matomo": { "tracked_sites": ["diegonmarcos.com"] },
    "photoprism": { "library": "/photoprism/originals" },
    "mattermost": { "team": "diegonmarcos" }
  }
}
```

---

## Markdown Exports

**Rule: every key in the JSON gets a table in the .md. 1:1 mirror, no exceptions.**

The Nunjucks templates iterate over every top-level and nested key in the JSON and render a table for each. If a new parser adds a key to the JSON, the template auto-renders it. No manual template updates needed for new data.

### `cloud-topology.md` (mirrors `cloud-topology.json`)

| JSON key | Table |
|----------|-------|
| `vms` | VM table: ID, alias, IP, WG IP, user, method, container count, description |
| `vms[].containers` | Per-VM container list: name, ports, networks |
| `vpss` | VPS providers: provider, tier, type, instances |
| `wireguard.peers` | WireGuard mesh: peer, WG IP, endpoint, role |
| `dns.zones[].records` | DNS records per zone: name, type, value |
| `services` | Services by VM: name, category, domain, ports, containers |
| `services` (grouped) | Services by category: name, flake folder, VM, domain, description |
| `networks` (derived) | Docker networks: network name, VM, connected containers |

### `cloud-configs.md` (mirrors `cloud-configs.json`)

| JSON key | Table |
|----------|-------|
| `infra.caddy.routes` | Caddy routes: domain, upstream, auth type, TLS, public paths |
| `infra.authelia.acl` | Authelia ACL: domain pattern, policy, subjects |
| `infra.hickory-dns.zones` | DNS zones: zone name, records |
| `apps.ntfy` | ntfy config: topics, users, auth settings |
| `apps.mailu` | Mailu config: domain, mailboxes, relay |
| `apps.*` | Every app with extractable config gets its own table |

**Template design**: loop over `Object.keys(data.infra)` and `Object.keys(data.apps)` — any new service added to the JSON automatically gets a section in the .md without template changes.

---

## Execution Steps

| # | What | File(s) |
|---|------|---------|
| 0 | Add dependency engine to `build.sh` | `cloud/build.sh` |
| 1 | Create `engines/`, `parsers/`, `templates/` dirs | `mcp-api-c3/src/engines/` |
| 2 | Write parsers: build-json, compose, ssh-config, caddyfile, authelia, wireguard, dns, ntfy, mailu | `mcp-api-c3/src/engines/parsers/` |
| 3 | Write `gen-topology.ts` | `mcp-api-c3/src/engines/` |
| 4 | Write `gen-configs.ts` | `mcp-api-c3/src/engines/` |
| 5 | Write Nunjucks templates for both .md exports | `mcp-api-c3/src/engines/templates/` |
| 6 | Update `cloud/build.sh cmd_config()` to use C3 engines | `cloud/build.sh` |
| 7 | Update C3-API Dockerfile: add git, entrypoint clones repos with force-pull | `mcp-api-c3/` |
| 8 | Update `paths.ts`: container `/app/repos`, local `~/git` | `mcp-api-c3/src/shared/paths.ts` |
| 9 | Add API routes `GET /topology`, `GET /configs` for remote consumers | `mcp-api-c3/src/` |
| 10 | Add MCP tools: `c3_routes`, `c3_acl`, `c3_mesh`, `c3_service_config` | `mcp-api-c3/src/mcp/tools/` |
| 11 | Rename `config.json` refs to `cloud-topology.json` everywhere | all files referencing config.json |
| 12 | Delete `cloud/tools/gen-config.ts`, `config.md.njk`, `config.json`, `config.md` | `cloud/tools/` |
| 13 | Update GHA workflows to deploy both JSON files to oci-apps | `.github/workflows/` |

---

## Desired Output — UI Validation

### `cloud-topology.md` (expected output)

```markdown
# Cloud Topology

> Auto-generated from `cloud-topology.json`. Run `./build.sh config` to regenerate.

## Virtual Machines

| VM ID | Alias | IP | WG IP | User | Method | Containers | Description |
|-------|-------|----|-------|------|--------|------------|-------------|
| `gcp-E2-f_0` | `gcp-proxy` | 35.226.147.64 | 10.0.0.1 | diego | gcloud | 6 | Reverse proxy + auth + DNS |
| `oci-E2-f_0` | `oci-mail` | 130.110.251.193 | 10.0.0.3 | opc | ssh | 3 | Mail + sync + calendar |
| `oci-E2-f_1` | `oci-analytics` | 129.151.228.66 | 10.0.0.4 | opc | ssh | 2 | Analytics + workflows |
| `oci-A1-f_0` | `oci-apps` | 82.70.229.129 | 10.0.0.6 | opc | ssh | 12 | Main app server |
| `oci-A1-f_1` | `oci-apps-1` | 144.24.196.72 | 10.0.0.2 | opc | ssh | 4 | Secondary apps |

### gcp-proxy (`gcp-E2-f_0`) — Containers

| Container | Ports | Networks |
|-----------|-------|----------|
| caddy | 80:80, 443:443 | npm_default |
| authelia | 9091 | npm_default |
| introspect-proxy | 4180 | npm_default |
| vaultwarden | 80 | npm_default |
| ntfy | 8090 | npm_default |
| hickory-dns | 53:53 | npm_default |

### oci-mail (`oci-E2-f_0`) — Containers

| Container | Ports | Networks |
|-----------|-------|----------|
| mailu-front | 8444:8443, 25:25, 465:465 | mailu_default |
| mailu-admin | 8080 | mailu_default |
| syncthing | 8384:8384 | syncthing_net |

### oci-analytics (`oci-E2-f_1`) — Containers

| Container | Ports | Networks |
|-----------|-------|----------|
| matomo | 8080:80 | matomo_net |
| windmill | 8000:8000 | windmill_net |

### oci-apps (`oci-A1-f_0`) — Containers

| Container | Ports | Networks |
|-----------|-------|----------|
| c3-api | 8081:8081 | c3_net |
| crawlee-api | 3000:3000 | crawlee_net |
| crawlee-worker | — | crawlee_net |
| kg-graph | 8082:8082 | c3_net |
| orchestrator | 8083:8083 | c3_net |
| lgtm-grafana | 3000 | lgtm_net |
| lgtm-loki | 3100 | lgtm_net |
| lgtm-prometheus | 9090 | lgtm_net |
| gitea | 3000:3000 | gitea_net |
| nocodb | 8085:8080 | nocodb_net |
| code-server | 8443:8443 | code_net |
| affine | 3010:3010 | affine_net |

### oci-apps-1 (`oci-A1-f_1`) — Containers

| Container | Ports | Networks |
|-----------|-------|----------|
| photoprism | 3013:2342 | photo_net |
| ollama-arm | 11434:11434 | ollama_net |
| mattermost | 8065:8065 | mm_net |
| mattermost-db | 5432 | mm_net |

## VPS Providers

| Provider | Tier | Type | Instances |
|----------|------|------|-----------|
| Oracle Cloud | free | E2.1.Micro | oci-E2-f_0, oci-E2-f_1 |
| Oracle Cloud | free | A1.Flex | oci-A1-f_0, oci-A1-f_1 |
| Google Cloud | free | e2-micro | gcp-E2-f_0 |

## WireGuard Mesh

| Peer | WG IP | Endpoint | Role |
|------|-------|----------|------|
| gcp-proxy | 10.0.0.1 | 35.226.147.64:51820 | hub |
| oci-apps-1 | 10.0.0.2 | 144.24.196.72:51820 | spoke |
| oci-mail | 10.0.0.3 | 130.110.251.193:51820 | spoke |
| oci-analytics | 10.0.0.4 | 129.151.228.66:51820 | spoke |
| oci-apps | 10.0.0.6 | 82.70.229.129:51820 | spoke |
| surface | 10.0.0.10 | dynamic | client |
| termux | 10.0.0.11 | dynamic | client |

## DNS Records (internal zone)

| Name | Type | Value |
|------|------|-------|
| proxy | A | 10.0.0.1 |
| apps | A | 10.0.0.6 |
| apps-1 | A | 10.0.0.2 |
| mail | A | 10.0.0.3 |
| analytics | A | 10.0.0.4 |

## Services by VM

### gcp-proxy

| Service | Category | Domain | Ports | Containers |
|---------|----------|--------|-------|------------|
| caddy | sec | proxy.diegonmarcos.com | 80, 443 | caddy, introspect-proxy |
| authelia | sec | auth.diegonmarcos.com | 9091 | authelia |
| vaultwarden | sec | vault.diegonmarcos.com | 80 | vaultwarden |
| ntfy | sec | rss.diegonmarcos.com | 8090 | ntfy |
| hickory-dns | sec | — | 53 | hickory-dns |

### oci-apps

| Service | Category | Domain | Ports | Containers |
|---------|----------|--------|-------|------------|
| c3-api | sec | api.diegonmarcos.com/c3-api | 8081 | c3-api |
| crawlee | cloud | api.diegonmarcos.com/crawlee | 3000 | crawlee-api, crawlee-worker |
| gitea | data | — | 3000 | gitea |

### oci-mail

| Service | Category | Domain | Ports | Containers |
|---------|----------|--------|-------|------------|
| mailu | app | mail.diegonmarcos.com | 8444, 25, 465 | mailu-front, mailu-admin |
| syncthing | app | sync.diegonmarcos.com | 8384 | syncthing |

### oci-analytics

| Service | Category | Domain | Ports | Containers |
|---------|----------|--------|-------|------------|
| matomo | tools | analytics.diegonmarcos.com | 8080 | matomo |
| windmill | tools | windmill.diegonmarcos.com | 8000 | windmill |

## Services by Category

### Security (bb-sec_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| caddy | bb-sec_caddy | gcp-proxy | proxy.diegonmarcos.com | Caddy reverse proxy |
| authelia | bb-sec_authelia | gcp-proxy | auth.diegonmarcos.com | 2FA authentication |
| vaultwarden | bb-sec_vaultwarden | gcp-proxy | vault.diegonmarcos.com | Password manager |
| ntfy | bc-obs_ntfy | gcp-proxy | rss.diegonmarcos.com | Push notifications |
| c3-api | bb-sec_mcp-server-skills | oci-apps | api.diegonmarcos.com/c3-api | Cloud control center |

### Suite (aa-sui_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| mailu | aa-sui_tools-mailu | oci-mail | mail.diegonmarcos.com | Email server |
| syncthing | aa-sui_tools-syncthing | oci-mail | sync.diegonmarcos.com | File sync |
| photoprism | aa-sui_photoprism | oci-apps-1 | photos.diegonmarcos.com | Photo management |

### Observability (bc-obs_*)

| Service | Flake | VM | Domain | Description |
|---------|-------|----|--------|-------------|
| matomo | bc-obs_matomo | oci-analytics | analytics.diegonmarcos.com | Web analytics |
| windmill | bc-obs_windmill | oci-analytics | windmill.diegonmarcos.com | Workflow automation |
| lgtm | bc-obs_lgtm | oci-apps | — | Grafana + Loki + Prometheus |

## Docker Networks

| Network | VM | Connected Containers |
|---------|----|---------------------|
| npm_default | gcp-proxy | caddy, authelia, introspect-proxy, vaultwarden, ntfy, hickory-dns |
| mailu_default | oci-mail | mailu-front, mailu-admin |
| c3_net | oci-apps | c3-api, kg-graph, orchestrator |
| crawlee_net | oci-apps | crawlee-api, crawlee-worker |
| matomo_net | oci-analytics | matomo |
```

---

### `cloud-configs.md` (expected output)

```markdown
# Cloud Configs

> Auto-generated from `cloud-configs.json`. Run `./build.sh config` to regenerate.

## Infrastructure

### Caddy Routes

| Domain | Upstream | Auth | TLS Skip | Public Paths |
|--------|----------|------|----------|--------------|
| auth.diegonmarcos.com | authelia:9091 | none | no | — |
| vault.diegonmarcos.com | vaultwarden:80 | authelia | no | — |
| rss.diegonmarcos.com | ntfy:80 | 3-tier | no | — |
| mail.diegonmarcos.com | 10.0.0.3:8444 | authelia+bearer | yes | — |
| analytics.diegonmarcos.com | 10.0.0.4:8080 | authelia+bearer | no | /matomo.js, /matomo.php, /js/* |
| photos.diegonmarcos.com | 10.0.0.2:3013 | authelia+bearer | no | — |
| chat.diegonmarcos.com | 10.0.0.2:8065 | authelia+bearer | no | /api/v4/websocket |
| api.diegonmarcos.com | 10.0.0.6:8081 | authelia+bearer | no | /c3-api/docs |
| ide.diegonmarcos.com | 10.0.0.2:8443 | authelia | yes | — |
| sync.diegonmarcos.com | 10.0.0.3:8384 | authelia | no | — |

### Authelia ACL

| Domain Pattern | Policy | Subjects |
|----------------|--------|----------|
| vault.* | two_factor | — |
| api.* | one_factor | — |
| *.diegonmarcos.com | one_factor | — |

### Hickory DNS

#### Zone: internal

| Name | Type | Value |
|------|------|-------|
| proxy | A | 10.0.0.1 |
| apps | A | 10.0.0.6 |
| apps-1 | A | 10.0.0.2 |
| mail | A | 10.0.0.3 |
| analytics | A | 10.0.0.4 |

## Applications

### ntfy

| Setting | Value |
|---------|-------|
| Topics | syslog, github-releases, alerts, health, backups |
| Users | admin, diego |
| Enable Login | true |
| Default Access | read-write |

### Mailu

| Setting | Value |
|---------|-------|
| Domain | diegonmarcos.com |
| Mailboxes | me@, no-reply@ |
| Relay | smtp.email.eu-marseille-1.oci.oraclecloud.com:587 |

### Matomo

| Setting | Value |
|---------|-------|
| Tracked Sites | diegonmarcos.com |

### PhotoPrism

| Setting | Value |
|---------|-------|
| Library | /photoprism/originals |

### Mattermost

| Setting | Value |
|---------|-------|
| Team | diegonmarcos |
```
