# Plan — `scrappers-api` (retire crawlee-cloud)

**Goal:** replace the 7-container Apify-compatible `user-fin_crawlee-cloud` platform with one lean
`scrappers-api` service, then retire crawlee entirely.
**Decisions (locked):** full replacement (my IG/Pinterest/LinkedIn profiles **+** crawlee's crawls) ·
lean runtime (single container, on-demand shell-out, flat JSON) · drop Postgres/Redis/MinIO.

---

## 1. What exists today (evidence)

`a_solutions/user-fin_crawlee-cloud/build.json` — **7 containers** on oci-apps (arm64, VM-built):

| container | image | role | ports |
|---|---|---|---|
| crawlee_api | crawlee-cloud-api | Apify-compat API (74 endpoints) | 3000 |
| crawlee_runner | crawlee-cloud-runner | actor runner (mounts docker.sock) | — |
| crawlee_dashboard | crawlee-cloud-dashboard | web UI | 3001 |
| crawlee_scheduler | crawlee-cloud-api (sleep) | cron (currently `sleep infinity`) | — |
| crawlee_db | postgres:16 | metadata | 5434 |
| crawlee_redis | redis:7 | queue | 6381 |
| crawlee_minio | minio | dataset/KV object store | 9000/9001 |

- Route: `api.diegonmarcos.com/crawlee/` · auth `two_factor` · category `fin`.
- **No custom actors/crawls committed** in `src/` — it's the bare platform. The real workload is light
  (my ~3 profiles + whatever ad-hoc finance crawls). Massive over-provisioning.
- Drift test (`c3-infra-api/src/test-drift-multi-container.ts`) already shows only **3 of 7** deployed.

**Consumers to repoint:**
- `infra-api_c3-services-mcp` → `registerCrawleeTools` (`src/code/mcp/tools/crawlee.ts`), ~7 `infra_crawlee_*` MCP tools.
- `infra-api_c3-services-mcp/.../discovery.ts` → registry list includes `"crawlee-cloud"`.
- `infra-api_c3-infra-api` dashboards → `crawlee-api.html`.
- `front` → `c-Cloud/api` project references crawlee.
- `9_others` derived data (caddy route, dns, topology) + backup DAG.

---

## 2. Target design — `user-data_scrappers-api` (name TBD)

**One container.** Python + FastAPI (the tools are Python: `instaloader`, `gallery-dl`, and my
`extract_*.py` export parsers). Model the service skeleton on `user-news_news-gdelt`
(single-container Node/py API with `Dockerfile.native`, `compose.nix`, `flake.nix`).

```
POST /scrape/instagram   { handle | export_zip }   -> JSON
POST /scrape/pinterest   { board_url }             -> JSON  (gallery-dl)
POST /scrape/linkedin    { export_zip }            -> JSON  (reuse extract_li_export.py)
POST /crawl              { url, selector | recipe } -> JSON  (httpx + selectolax; or crawlee-js lib if a crawl needs a headless browser)
GET  /health
GET  /openapi.json  (public)
```

- **Data-driven targets** — `scrappers.json` (service `src/` or `9_others/inputs/`) lists
  `{platform, handle/url, schedule, output_path}`. Engine reads it; **no hardcoded handles**.
- **Output** — flat JSON to a mounted, restic-backed dir (`backup.enabled`), optionally pushed to
  `front-data` / gitea. No DB, no object store.
- **Auth** — `two_factor` via Caddy `forward_auth` (same as crawlee); `/openapi.json` public.
- **Scheduling** — a **Dagu DAG** (existing `infra-obs_dagu`) cron-triggers `POST /scrape/*`.
  Replaces crawlee's dead scheduler container.
- **Secrets** — `src/secrets.yaml` (sops): IG session cookie (if live scraping), any crawl creds.
- **Reality check baked into the plan:** IG/LinkedIn heavily anti-bot live scraping. The **reliable**
  path for *my own* profiles is the official-export upload endpoints (what I already did for LinkedIn).
  Live `instaloader`/`gallery-dl` are best-effort for public/incremental pulls.
- **IG account is PRIVATE** — anonymous scraping returns nothing. To pull my posts/followers/
  highlights/reels/tagged, scrappers-api must run a **dedicated burner IG account** that I accept as a
  follower/friend; the burner (never my main) holds the session in `secrets.yaml`, rate-limited, on the
  VM. The main account is never used for scraping (block risk). IG-export upload remains the zero-risk
  fallback. (mySocials MVP uses screenshots/fabrication until this lands.)

---

## 3. Phases (each with its tester — FIRE rule 5)

**Phase 0 — Confirm crawlee's real workload.** Inspect the running crawlee DB/minio on oci-apps
(read-only) for any actors/datasets actually in use. If empty → retirement is trivial. **Tester:**
documented list of live actors (or "none").

**Phase 1 — Scaffold `scrappers-api`.** Copy universal `build.sh`; author `build.json`
(single container, route, auth, backup), `flake.nix`, `compose.nix`, `Dockerfile.native`, FastAPI
skeleton with `/health` + `/openapi.json`. **Tester:** `build.sh build` green; `/health` 200 on oci-apps.

**Phase 2 — Modules.** Implement instagram/pinterest/linkedin/crawl handlers + `scrappers.json`
targets. Reuse `extract_li_export.py`; add `extract_ig.py`/pinterest parsers. **Tester:** each endpoint
returns valid JSON for a known target; LinkedIn output byte-identical to current `linkedin.json` shape.

**Phase 3 — Dagu schedule.** Add DAG that calls `/scrape/*` on cron, writes JSON to the data store.
**Tester:** manual DAG run green; output file present + valid.

**Phase 4 — Repoint consumers.** Rewrite `c3-services-mcp` crawlee tools → `scrappers` tools (new
endpoints); update `discovery.ts` registry, `c3-infra-api` dashboard, `front c-Cloud/api`, and the
drift test. **Tester:** MCP tool call hits scrappers-api; drift test passes; dashboards resolve.

**Phase 5 — Cutover + retire crawlee.** Ship scrappers-api; run parallel one cycle; then remove
`user-fin_crawlee-cloud` (service dir, GHA path trigger, Caddy route, DNS). **Volumes:**
`crawlee_postgres/redis/minio` deletion is **hook-blocked** (`down -v`, `volume rm`) — back up via
restic + get explicit approval before removing; otherwise leave orphaned. **Tester:**
`api.diegonmarcos.com/crawlee/` 404; scrappers route 200; `docker ps` on oci-apps shows no `crawlee_*`.

**Phase 6 — Cleanup.** Delete crawlee GHCR images, docs, `9_others` references; regenerate derived
data. **Tester:** `grep -r crawlee` across repos returns only historical/plan references.

---

## 4. Payoff & risks

- **Payoff:** 7 → 1 container on oci-apps; drops Postgres + Redis + MinIO (~300–500 MB RAM + volumes)
  on a memory-tight A1 VM. One small codebase instead of a patched upstream fork.
- **Risks:** (a) live IG/LinkedIn scraping is anti-botted — lean on official exports; (b) if Phase 0
  finds real crawlee crawls, they must be ported to `/crawl` before retire, not dropped;
  (c) volume deletion needs backup + approval (hook-guarded); (d) Python service in a Node-heavy stack
  (acceptable — the scraping tools are Python).

## 5. Open decisions for you
1. Service name/prefix: `user-data_scrappers-api` vs `bc-obs_scrappers-api` (tools) vs keep `fin`?
2. Python/FastAPI (natural for the tools) — OK, or force Node to match the rest of the stack?
3. Live scraping vs export-upload-only for IG/LinkedIn (I recommend export-first, live best-effort).
