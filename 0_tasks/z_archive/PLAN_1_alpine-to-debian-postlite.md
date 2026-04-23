# Task: Postlite Alpine to Debian Migration

## Summary
Migration of postlite Docker build from Alpine Linux (musl libc) to Debian (glibc) to resolve SQLite CGO compilation issues.

## Problem

### Error with Alpine
```
sqlite3-binding.c: error: expected ')' before '__attribute__'
...
/go/pkg/mod/github.com/mattn/go-sqlite3@v1.14.12/sqlite3-binding.c:30251:47: error: expected ')' before '__attribute__'
30251 | static int osPwrite64(int a, const void *b, int c, long int d) __attribute__((weak));
```

### Root Cause
**musl libc vs glibc incompatibility**

- Alpine Linux uses **musl libc** - a lightweight C standard library
- SQLite's CGO bindings use low-level C functions (`osPwrite64`, `osFcntl`, etc.)
- musl libc defines these functions differently than glibc
- The `__attribute__((weak))` syntax is parsed differently by musl's headers
- This causes compilation to fail when building the `go-sqlite3` package

### Why Debian Works
- Debian uses **glibc** (GNU C Library)
- glibc is the standard C library used by most Linux distributions
- SQLite CGO bindings are designed and tested against glibc
- The `go-sqlite3` package compiles successfully with glibc

## Solution

### Old Dockerfile (Alpine - BROKEN)
```dockerfile
FROM golang:alpine AS builder
RUN apk add --no-cache gcc musl-dev
WORKDIR /build
RUN git clone https://github.com/benbjohnson/postlite.git .
RUN CGO_ENABLED=1 go build -o postlite ./cmd/postlite

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /build/postlite /usr/local/bin/postlite
EXPOSE 5432
ENTRYPOINT ["postlite"]
```

### New Dockerfile (Debian - WORKING)
```dockerfile
FROM golang:1.21-bookworm AS builder
RUN apt-get update && apt-get install -y gcc libc6-dev
WORKDIR /build
RUN git clone https://github.com/benbjohnson/postlite.git .
RUN CGO_ENABLED=1 go build -tags vtable -o postlite ./cmd/postlite

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/postlite /usr/local/bin/postlite
EXPOSE 5432
ENTRYPOINT ["postlite"]
```

**IMPORTANT**: The `-tags vtable` flag is required because postlite uses SQLite virtual tables (VTab, VTabCursor, etc.) which are only available when go-sqlite3 is built with the vtable tag.

### Key Changes
| Aspect | Alpine | Debian |
|--------|--------|--------|
| Builder base | `golang:alpine` | `golang:1.21-bookworm` |
| C compiler | `apk add gcc musl-dev` | `apt-get install gcc libc6-dev` |
| C library | musl libc | glibc |
| Runtime base | `alpine:latest` | `debian:bookworm-slim` |
| CA certs | `apk add ca-certificates` | `apt-get install ca-certificates` |
| Image size | ~15 MB | ~50 MB |

## Deployment

### Location on GCloud
```
Server: gcp-f-micro_1 (35.226.147.64)
Path: /home/diego/postlite/
```

### Files
- `Dockerfile` - Debian-based build
- `docker-compose.yml` - Service definitions for ws4sqlite + postlite

### Build Command
```bash
cd /home/diego/postlite
docker build -t postlite:latest .
```

### Services (docker-compose.yml)

#### ws4sqlite (REST API for SQLite)
```yaml
services:
  sqlite-npm:
    image: germanorizzo/ws4sqlite:latest
    ports: ["10.0.0.1:8880:12321"]
    command: ["-db", "/data/database.sqlite?mode=ro"]

  sqlite-vaultwarden:
    image: germanorizzo/ws4sqlite:latest
    ports: ["10.0.0.1:8881:12321"]
    command: ["-db", "/data/db.sqlite3?mode=ro"]

  sqlite-ntfy:
    image: germanorizzo/ws4sqlite:latest
    ports: ["10.0.0.1:8882:12321"]
    command: ["-db", "/data/cache.db?mode=ro"]
```

#### postlite (PostgreSQL wire protocol for SQLite)
```yaml
services:
  postlite-npm:
    image: postlite:latest
    ports: ["10.0.0.1:5433:5432"]
    command: ["-addr", ":5432", "-dsn", "/data/database.sqlite"]

  postlite-vaultwarden:
    image: postlite:latest
    ports: ["10.0.0.1:5434:5432"]
    command: ["-addr", ":5432", "-dsn", "/data/db.sqlite3"]

  postlite-ntfy:
    image: postlite:latest
    ports: ["10.0.0.1:5435:5432"]
    command: ["-addr", ":5432", "-dsn", "/data/cache.db"]
```

## Status

| Task | Status |
|------|--------|
| Create Debian Dockerfile | ✅ Complete |
| Add `-tags vtable` flag | ✅ Complete |
| Build on GCloud | 🔄 In Progress (rebuilding) |
| Deploy ws4sqlite containers | ✅ Running |
| Deploy postlite containers | ⏳ Pending (3 containers) |
| Connect to NocoDB | ⏳ Pending |

## Alpine→Debian Migration (Oracle VMs)

| VM | Container | Before | After | Status |
|----|-----------|--------|-------|--------|
| oci-f-micro_1 | palantir-cron | alpine:3.19 | debian:bookworm-slim | ✅ Deployed |
| oci-f-micro_1 | mailu-redis | redis:7-alpine | redis:7-bookworm | ✅ Deployed |
| oci-f-micro_2 | sauron-forwarder | alpine:3.19 | debian:bookworm-slim | ✅ Deployed |
| oci-p-flex_1 | nocodb-db | postgres:16-alpine | postgres:16-bookworm | ✅ In compose |

## Postlite Containers (3 remaining on GCloud)

| Container | Port | SQLite DB | Status |
|-----------|------|-----------|--------|
| postlite-npm | 5433 | NPM database.sqlite | ⏳ Pending |
| postlite-vaultwarden | 5434 | Vaultwarden db.sqlite3 | ⏳ Pending |
| postlite-ntfy | 5435 | ntfy cache.db | ⏳ Pending |

## SQLite Databases Found (Oracle VMs)

### oci-f-micro_1 (130.110.251.193)
| Database | Path | Service |
|----------|------|---------|
| NPM | /home/ubuntu/matomo/npm/data/database.sqlite | Nginx Proxy Manager |
| Mailu | /opt/mailu/data/main.db | Mail server |
| Roundcube | /opt/mailu/webmail/roundcube.db | Webmail |

### oci-f-micro_2 (129.151.228.66)
No application SQLite databases found.

### oci-p-flex_1 (144.24.196.72) - Wake-on-demand
⏳ Pending scan (VM needs to be started)

## Build Progress

```
[builder 1/5] FROM golang:1.21-bookworm ✅
[builder 2/5] apt-get install gcc libc6-dev 🔄 (in progress)
[builder 3/5] WORKDIR /build ⏳
[builder 4/5] git clone postlite ⏳
[builder 5/5] go build -tags vtable ⏳
```

## Next Steps

1. Wait for postlite build to complete
2. Run `docker compose up -d postlite-npm postlite-vaultwarden postlite-ntfy`
3. Test PostgreSQL wire protocol connections:
   ```bash
   psql -h 10.0.0.1 -p 5433 -U any -d any  # NPM SQLite
   psql -h 10.0.0.1 -p 5434 -U any -d any  # Vaultwarden SQLite
   psql -h 10.0.0.1 -p 5435 -U any -d any  # ntfy SQLite
   ```
4. Add as external databases in NocoDB (db.diegonmarcos.com)

## NocoDB Integration Plan

To connect SQLite databases to NocoDB, we need postlite running on each VM to provide PostgreSQL wire protocol.

### Required postlite instances:

| VM | Database | Postlite Port | NocoDB Connection |
|----|----------|---------------|-------------------|
| gcp-f-micro_1 | NPM database.sqlite | 5433 | pg://10.0.0.1:5433 |
| gcp-f-micro_1 | Vaultwarden db.sqlite3 | 5434 | pg://10.0.0.1:5434 |
| gcp-f-micro_1 | ntfy cache.db | 5435 | pg://10.0.0.1:5435 |
| oci-f-micro_1 | Mailu main.db | 5433 | pg://130.110.251.193:5433 |
| oci-f-micro_1 | Roundcube roundcube.db | 5434 | pg://130.110.251.193:5434 |

### Steps:
1. Build postlite on GCloud 🔄 (in progress)
2. Build postlite on oci-f-micro_1 🔄 (in progress)
3. Deploy postlite containers ⏳
4. Configure NocoDB external connections ⏳

### Build Status:
| VM | Status | Containers |
|----|--------|------------|
| gcp-f-micro_1 | ✅ **DEPLOYED** | postlite-npm (5433), postlite-vaultwarden (5434), postlite-ntfy (5435) |
| oci-f-micro_1 | 🔄 Building | postlite-mailu (5433), postlite-roundcube (5434) |

## Secrets Management

All hardcoded secrets moved to age-encrypted files:

| Folder | File | Keys |
|--------|------|------|
| vm_oci-p-flex_1/nocodb | secrets.age | POSTGRES_PASSWORD, NC_OIDC_CLIENT_SECRET |
| vm_oci-p-flex_1/photoprism | secrets.age | PHOTOPRISM_ADMIN_PASSWORD, DB_PASSWORD, ROOT_PASSWORD |
| vm_oci-f-micro_2/matomo | secrets.age | MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD |
| vm_oci-f-micro_1/palantir-monitor | secrets.age | SMTP_PROXY_API_KEY |
| vm_oci-f-micro_1/smtp-proxy | secrets.age | SMTP_PROXY_API_KEY |
| vm_oci-f-micro_1/mailu | secrets.age | SECRET_KEY, RELAYPASSWORD |
| vm_gcp-f-micro_1/vaultwarden | secrets.age | ADMIN_TOKEN, SMTP_PASSWORD |

**Decrypt:** `age -d -i /home/diego/Mounts/Git/vault/A0_keys/age/keys.txt secrets.age`
**Helper:** `./b_infra/encrypt.sh -d secrets.age`

## References

- [postlite GitHub](https://github.com/benbjohnson/postlite)
- [go-sqlite3 CGO issues](https://github.com/mattn/go-sqlite3/issues)
- [musl vs glibc differences](https://wiki.musl-libc.org/functional-differences-from-glibc.html)
- [ws4sqlite](https://github.com/proofrock/ws4sqlite)

---
Created: 2026-02-04
VM: gcp-f-micro_1
Author: Claude Code
