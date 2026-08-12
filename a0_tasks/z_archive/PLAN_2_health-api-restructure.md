# Plan: Tiered Health System + API Route Restructure + Go API

## Context

Three changes:
1. **Tiered health endpoints**: Replace 11 flat health routes with a clean 5-tier escalation (declared -> deployed -> drift -> status -> profiling)
2. **API route restructure**: Rust API becomes default at `api.diegonmarcos.com/*`, Flask moves to `/flask/*`, new Go API at `/go/*`
3. **Go API project**: New cloud service project mirroring rust-api endpoints (not deployed yet, but full flake + build.sh + docker-compose)

---

## Part A: API Route Restructure

### Current routing (Caddy `flake.nix` line 699):
```
api.diegonmarcos.com {
    handle /rust/* { reverse_proxy gcp:8080 }  # Rust API (public)
    handle { reverse_proxy gcp:5000 }           # Flask API (Authelia-protected, catch-all)
}
```

### New routing:
```
api.diegonmarcos.com {
    handle /flask/* { reverse_proxy gcp:5000 }  # Flask (protected, move to /flask/*)
    handle /go/*    { reverse_proxy gcp:8090 }  # Go API (future, port 8090)
    handle         { reverse_proxy gcp:8080 }   # Rust API (default, catch-all)
}
```

### Rust API path changes:
- Currently all routes have `/rust/` prefix (e.g., `/rust/health`, `/rust/profiling/{container}`)
- Change prefix from `/rust/` to `/api/` (since it's now the default API)
- Swagger UI: `/rust/api-docs` -> `/api/docs`

---

## Part B: Tiered Health Endpoints

### Final endpoint design (under new `/api/` prefix):

```
GET /api/health                        - Alive check
GET /api/health/declared               - Tier 0: config.rs services/containers (no SSH)
GET /api/health/deployed               - Tier 1: docker ps -a all VMs (parallel SSH)
GET /api/health/deployed/{vm_id}       - Tier 1: docker ps -a one VM
GET /api/health/drift                  - Tier 2: declared vs deployed diff
GET /api/health/status                 - Tier 3: full health + resources + routes
GET /api/health/status/{vm_id}         - Tier 3: per-VM
GET /api/profiling/{container}         - Tier 4: 8-check diagnostic (existing logic)
GET /api/profiling/vm/{vm_id}          - Tier 4: batch profile all containers on VM
```

9 endpoints total. All old health endpoints removed.

---

## Part C: Go API Project

New project: `bb-sec_go-api` at port 8090. Mirrors the rust-api with identical endpoint paths under `/go/` prefix. Same health tiers + profiling + VM/container actions. Not deployed yet.

---

## Part D: Health Dashboard (proxy.diegonmarcos.com index.html)

### Add "Health" section to the Caddy dashboard page with tables powered by the tiered health endpoints.

**Key design:**
- **Lazy load**: No API calls on page load. Each section has a "Refresh" button.
- **Load tiers from lightest to heaviest**:
  - Declared (instant) -> Deployed (~3s) -> Drift (~3s) -> Status (heavy) -> Profiling (heaviest)
- **Tables**:
  1. **Declared** table: VMs x services/containers (static config, instant)
  2. **Deployed** table: VMs with container states (running/stopped counts)
  3. **Drift** table: missing/extra containers per VM
  4. **Status** table: comprehensive VM health (provider state, SSH, resources)
  5. **Profiling** table: per-container diagnostic (individual refresh per container)

**Profiling is expensive** - never auto-load, always manual per-container trigger.

---

## Implementation Status

- [x] Step 1: Rust API - new health.rs (tiers 0-3)
- [x] Step 2: Rust API - batch profiling
- [x] Step 3: Rust API - clean up ondemand.rs
- [x] Step 4: Rust API - route prefix /rust/ -> /api/
- [x] Step 5: Rust API - register routes + OpenAPI
- [x] Step 6: Caddy - rewrite API routing
- [x] Step 7: Go API - create project scaffold
- [x] Step 8: Add go-api to config.json
- [ ] Step 9: Build & deploy (Rust API + Caddy only, Go not deployed)
- [x] Step 10: Health dashboard in proxy.diegonmarcos.com index.html

---

## Critical Files Changed

| File | Change |
|------|--------|
| `bb-sec_rust-api/src/src/src/routes/health.rs` | **New**: tiers 0-3 (~350 lines) |
| `bb-sec_rust-api/src/src/src/routes/profiling.rs` | Add batch profiling + /api/ prefix |
| `bb-sec_rust-api/src/src/src/routes/ondemand.rs` | Remove health handlers, /api/ prefix, pub(crate) helpers |
| `bb-sec_rust-api/src/src/src/routes/mod.rs` | Register health module |
| `bb-sec_rust-api/src/src/src/main.rs` | /api/docs, updated OpenAPI paths |
| `bb-sec_rust-api/src/flake.nix` | Updated healthcheck URL |
| `bb-sec_rust-api/build.json` | Updated description |
| `bb-sec_caddy/src/flake.nix` | API routing rewrite |
| `bb-sec_go-api/` | **New project**: build.json, build.sh, src/flake.nix, Go source |
| `config.json` | Add go-api entry |

---

## Verification

1. `curl /api/health` - alive (rust-api, default)
2. `curl /api/health/declared` - config.rs data
3. `curl /api/health/deployed` - docker ps all VMs
4. `curl /api/health/drift` - declared vs deployed
5. `curl /api/health/status` - comprehensive health
6. `curl /api/profiling/authelia` - per-container diagnostic
7. `curl /api/profiling/vm/oci-p-flex_1` - batch VM profiling
8. `curl /flask/docs` - Flask API still accessible
9. `curl /go/health` - 502 (not deployed yet, expected)
10. Go project builds locally: `cd bb-sec_go-api && bash build.sh build`
