# PLAN — Enterprise Hardening: Tiered Reports · Bulletproof VMs · Notification System

> Date: 2026-07-07 · Owner: Diego · Scope: `cloud-data/reports`, `cloud/b_infra/_shared/vm-pilot`, `cloud/a_solutions/infra-obs_ntfy`, `unix` protection flakes
> Status: **DRAFT — awaiting approval before any code.**

---

## 0. Why this plan exists (the core insight)

Three parallel scans + a live probe on 2026-07-07 surfaced one damning fact:

- The latest generated report (`reports/dist/cloud_health_daily.json`, 2026-07-02) claims **all 4 VMs CRITICAL, 38 certs expired, mail stack down**.
- A live `curl` at plan time returned `auth`, `rss`, `mail` all **HTTP 200/301/302 with valid TLS** (`ssl_verify_result:0`).

**The infra was healthy; the reports were stale and nobody was told either way.** That is the whole problem in one sentence:

1. We probe **shallow** (URLs), store **snapshots** nobody reads, and have **no live alert loop**.
2. The protection stack keeps the *box* alive but lets *apps* die silently with manual-only recovery.
3. A rich 17-topic ntfy taxonomy **already exists** (data-driven in `infra-obs_ntfy/build.json`) but is **unused** — every agent posts to the single `health_resources` firehose.

This plan does not invent much. It **wires up what already exists** and closes the gaps.

### Locked decisions (from 2026-07-07 Q&A)

| Fork | Decision |
|------|----------|
| Bulletproof definition | **Island + tier-1 apps** — WG/SSH/Dropbear never die AND maddy/stalwart (oci-mail) + caddy (gcp-proxy) get reserved memory + auto-restart. |
| Report tiers | **4 tiers + on-demand** — T0 heartbeat ~30s, T1 probes ~2m, T2 deep ~15m, T3 forensic daily, on-demand per-host. |
| Notifications | **All four** — severity+dedup+escalation · multi-channel routing · structured topics · digest + status page. |
| Deliverable | **Plan doc first** (this file). No code until approved. |

---

## 1. Bugs & gaps found in the scan (Phase 0 targets)

These are concrete defects, not design. Every one is a "fix the engine, data-drive it" item per FIRE rules.

### 1A. Reports engine (`cloud-data/reports`)

| # | Bug | File | Fix |
|---|-----|------|-----|
| R1 | **No staleness detection** — a report from days ago is served as if fresh; false RED masks reality (and would mask a real outage too). | `reports-common/src/run_state.rs`, `output.rs` | Stamp `generated_at` + `max_age`; renderer marks report STALE if older than tier cadence. Tester: backdate `_run_state.json`, assert STALE banner. |
| R2 | **Hardcoded DNS resolvers** `10.0.0.1` / `1.1.1.1` / `8.8.8.8`. | `reports-common/src/checks.rs:10,62,72` | Read from `build-reports.json` (already the config SoT, exists at `1_cicd/dist/build-reports.json`). |
| R3 | **Hardcoded mail submission endpoints** `smtps://10.0.0.3:465`, `:2465`. | `cloud-health-full-daily/src/send.sh:36-37` | Derive from consolidated JSON `vms[].services[]`. |
| R4 | **`MAIL_PORTS` TODO stub** — mail port check never implemented. | `cloud-health-full-daily/src/health_full2/stack/sections.rs` | Implement as data-driven port list from build-caddy.json L4 map. |
| R5 | **Recon apex hardcoded fallback** `diegonmarcos.com`. | `reports/recon/recon.sh:18` | Fail loud if consolidated JSON missing; do not silently fall back. |
| R6 | **Bearer token absent in env** → all OIDC/private checks false-fail. | `reports/docker-compose.yml:42`, `entrypoint.sh` | Pull pre-signed JWT from vault path (already exists: `vault/A0_keys/providers/authelia/signed-bearer_jwt/`); fail loud if missing, don't run blind. |
| R7 | **WG-down cascade** — mesh down silently zeros every SSH/DNS metric, indistinguishable from real VM death. | `entrypoint.sh:241+` | Explicit `capabilities.rs` gate: if WG down, mark checks UNKNOWN (not CRITICAL). Prevents the exact false-RED we saw. |

### 1B. vm-pilot protection (`cloud/b_infra/_shared/vm-pilot`)

| # | Bug | File | Fix |
|---|-----|------|-----|
| P1 | **Load-shedder never notifies** — it stops docker (full app outage) and only writes a syslog line + `/run/load-shedder.fired`. No ntfy. | `protection/load-shedder.nix:55,70,77` | Post to `health_resources` (→ later `health_containers`/`page`) on shed + on recovery. Same `ntfy()` pattern watchdog-petter.sh already uses. |
| P2 | **No fd-exhaustion watchdog** — limits raised after the 2026-06-19 fluent-bit EMFILE incident, but nothing watches `/proc/sys/fs/file-nr`. This is a direct "box freezes / mesh dies" vector. | `protection/resource-bouncer.nix:45-60` | Add fd-pressure check to health-agent; alert at 70%/90% of `file-max`. |
| P3 | **WireGuard monitored as binary up/down only** — `ip link show wg0` says "up" even when peers are unreachable. | `agents/health-agent.nix:24` | Add handshake-age + peer-reachability check (`wg show` latest-handshake). Feeds T0 heartbeat. |
| P4 | **Thresholds hardcoded in Nix** (PSI 50, interval 15s, backoff 120s, disk 80/85/90). Tuning needs a rebuild. | `load-shedder.nix:31-34`, `watchdog-petter.sh:232-234` | Move to per-VM `protection` block in `_cloud-data-consolidated.json`; modules read it (pattern already used for ram/cpu/rescue_port). |
| P5 | **Silent activation swallow** — load-shedder deploy failure logs to stderr and continues; only caught next 5-min health cycle. | `load-shedder.nix:141` | Already writes `/run/load-shedder.deploy-failed`; wire that marker to an immediate ntfy `page` on next health tick. |

### 1C. Desktop/VM protection divergence (`unix`)

| # | Gap | Where | Note |
|---|-----|-------|------|
| U1 | Desktop hardcodes `cpus=8/ram=8192/rescue=2200`; VMs are data-driven. | `unix/aa_desk-usr.../configuration_system-protection.nix` | Converge desktop onto the same JSON schema (`cloud-data-system-protection.json` exists — extend it). |
| U2 | `PLAN-resource-bouncer.md` proposes merging two split `nix.settings` blocks; never done. | `unix/PLAN-resource-bouncer.md` | Fold into Phase 2; low-risk. |
| U3 | Guardrails module disabled ("login debugging"). | `unix/ba_flakes_desktop/.../system-protection-guardrails.nix:256-264` | Decide: delete or re-enable. Don't leave dead code. |

---

## 2. Phase 1 — Tiered "McAfee-level" reports engine

**Goal:** 4 scan tiers, each cheaper→deeper, staggered so 1GB VMs never feel it. Reuse `reports-common` (already has `caddy.rs`, `fleet.rs`, `ssh.rs`, `probe.rs`, `checks.rs`, `capabilities.rs`).

### Tier model (data-driven cadence in `build-reports.json`)

| Tier | Cadence | Cost | What it checks | Runs where |
|------|---------|------|----------------|------------|
| **T0 heartbeat** | ~30s | ~nothing (1 TCP + 1 UDP per host) | Mesh liveness: WG handshake age, Dropbear `:2200` reachable, SSH `:22` reachable. **Only the island.** | On-VM (health-agent), pushes to `health_mesh` |
| **T1 probe** | ~2m | cheap | Public URLs, port scan, TLS handshake+expiry-days, DNS resolution. No SSH. | Edge / GHA |
| **T2 deep** | ~15m | medium | SSH into VMs: container health, PSI (mem/cpu/io), disk%, fd usage, swap, cert SAN match, per-service memory vs cap. | GHA over WG |
| **T3 forensic** | daily | heavy | Log-mining (auth/err/OOM patterns from journald), **Caddy config audit** (routes declared vs live), **mesh structure audit** (peers declared vs handshaking), CVE/image scan, YARA, secrets scan, backup freshness. | GHA / oci-apps builder |
| **on-demand** | manual | per-host | Full forensic dump for one host (the existing `server-scanning.sh` / `url-triage.sh` promoted into the crate). | Any |

### New checks not currently done (the "deeper" asks)

- **Caddy structure audit** — parse `build-caddy.json` (the routing SoT) → assert every declared route resolves + responds; flag routes live-but-undeclared and declared-but-dead. (`reports-common/caddy.rs` already exists as a seed.)
- **Mesh structure audit** — parse WG peer list from consolidated JSON → assert each peer has a recent handshake; detect asymmetric/half-open tunnels (the 2026-05-28 silent-drop class).
- **Log reading** — tail-and-classify journald on each VM: OOM kills, EMFILE/fd errors, docker restarts, auth brute-force, load-shedder fires. Cheap `journalctl -p err --since` over SSH in T2/T3, classified in Rust.
- **fd / PSI / swap trend** — not just point value; T2 keeps a small rolling window in `dist/history/` (append-only JSONL, capped) so "was red yesterday" correlation works.
- **Cert SAN mismatch** (not just expiry) and **backup age** verification.

### Efficiency doctrine (your "low-level, minimal mem/cpu")

- Reuse the single Cargo workspace + `reports-common`; no new heavy deps.
- T0/T1 are pure TCP/HTTP probes with hard timeouts — no allocations beyond a result struct.
- History is append-only JSONL with a line cap, not a DB. `// ponytail: JSONL ring, add sqlite only if query latency matters`.
- T3 heavy tools (nuclei/YARA/trivy) run **only** on the oci-apps builder or GHA, never on 1GB VMs (matches the "slow VMs are collect-only" doctrine).

### Deliverables

- `build-reports.json` gains a `tiers` block: `{ t0:{interval,checks[]}, t1:{...}, ... }` — cadence + check-list data-driven.
- New crate `cloud-tier-scan` (or extend existing binaries with a `--tier` flag; lazier — decide at build).
- **Tester:** each tier has a golden-input fixture → assert classification (GREEN/YELLOW/RED/UNKNOWN/STALE). Add to `reports/src/*/tests/`.

---

## 3. Phase 2 — Bulletproof VMs (Island + tier-1 apps)

**Goal:** oci-mail and gcp-proxy never freeze; mesh/SSH/Dropbear are OOM-immune; maddy/stalwart/caddy get reserved memory + auto-restart.

### 3A. Harden the connectivity island (already exists, close the gaps)

- Confirm `connectivity.slice` holds WG + sshd + Dropbear + load-shedder with `OOMScoreAdjust≤-900`, `MemoryMin`, FIFO. (Present in `scheduler.nix`/`rescue-ssh.nix`.)
- **Add fd protection to the island** (P2): per-daemon `LimitNOFILE` on wg/sshd/dropbear so a system-wide fd leak can't starve `accept()` (the 2026-06-19 class).
- **T0 heartbeat** (Phase 1) becomes the island's liveness proof, pushed to `health_mesh` every 30s; miss → immediate `page`.

### 3B. Tier-1 app protection (the new part)

Define a **data-driven service tier** in `_cloud-data-consolidated.json` per VM:

```
vms.oci-mail.protection.tier1_services = ["maddy","stalwart"]
vms.gcp-proxy.protection.tier1_services = ["caddy","introspect-proxy"]
```

For each tier-1 service, generate (in a new `protection/tier1-apps.nix`):
- A dedicated cgroup sub-slice under `workload.slice` with `MemoryMin` (reserved, unreclaimable) + `MemoryHigh`.
- An **auto-restart supervisor** scoped to tier-1 only (a small watchdog, NOT compose `restart:always` — respects the no-blanket-restart rule; it's a targeted, logged, rate-limited healer with a circuit breaker → `page` after N restarts).
- Load-shedder **exempts** tier-1 services: on shed it stops non-tier-1 containers first, only touching tier-1 as absolute last resort, and **always notifies**.

> This is the one place we relax "no auto-restart": scoped to 2-4 named critical services, rate-limited, circuit-broken, and every action notified. Documented as a deliberate carve-out.

### 3C. Graduated shedding (not all-or-nothing)

Current load-shedder = binary "stop ALL docker at PSI≥50". Replace with graduated response driven by `build`-config thresholds:
1. PSI≥40 (warn): notify `health_resources`, no action.
2. PSI≥50 sustained: stop **non-tier-1** containers (biggest-memory first), notify.
3. PSI≥65 sustained: stop tier-1 too (last resort), `page`.
4. Recovery: after backoff, auto-restore tier-1; non-tier-1 stays down pending decision (or auto per config).

### Deliverables

- `protection/tier1-apps.nix` (new), `load-shedder.nix` (graduated + notify + tier-exempt), thresholds → consolidated JSON (P4).
- Desktop convergence (U1/U2/U3).
- **Tester:** `stress-ng --vm` harness on a scratch VM asserting: (a) island survives, (b) tier-1 survives until last resort, (c) ntfy fired, (d) auto-restore worked. Design as a dispatchable GHA job against a disposable VM — never on termux.

---

## 4. Phase 3 — Enterprise notification system

**Goal:** severity + dedup + escalation + multi-channel routing over the **existing** 17-topic taxonomy, plus digest + status page. Runs **in parallel** with Phases 1-2.

### 4A. The routing engine (new, data-driven)

A small notification broker (extend `infra-obs_ntfy` or the C3 API — decide; lazier = a Rust/py module in ntfy service) that all producers post *events* to instead of posting raw to `health_resources`:

```
event { source, severity(info|warn|crit|page), key, title, body, host, service }
```

Engine responsibilities (all config in a new `build-notify.json` data file):
- **Severity map** — event class → level.
- **Routing table** — (service, severity) → channels. Reuse existing topics:
  - `info`→`health_*`/`dev_*`/`deploy_*` (as today), `warn`→topic + de-dup,
  - `crit`→`sec_*`/`health_*` topic **+ Matrix room**, `page`→topic **+ Matrix + email** (maddy/resend).
- **Dedup / rate-limit** — collapse identical `key` within window; replaces journal-ntfy's crude per-service 5-min mute.
- **Flap detection** — N transitions in M minutes → single "flapping" notice.
- **Escalation** — `warn` unacked 15m → `crit` → `page`. Ack via ntfy action button.
- **Recovery notices** — auto "resolved" when the condition clears (paired by `key`).

### 4B. Structured topics (mostly already there)

The taxonomy in `infra-obs_ntfy/build.json` is good and data-driven. Changes:
- Add `mesh`-priority tags + click-actions (→ status page) + emojis per topic.
- **Retire the firehose habit:** update `journal-ntfy.nix`, `load-shedder.nix`, watchdog to emit *events to the broker*, which routes to the right topic — not hardcode `health_resources`.

### 4C. Digest + status page

- **Digest:** daily 08:00 + weekly rollup → `ops_reports` topic + email. Fed by T2/T3 history JSONL.
- **Status page:** `status.diegonmarcos.com` (or `/status` on edge) — static JSON (`status.json`) written by the tiered reports, rendered green/yellow/red per service. Served from Caddy edge; no new service if it's a static file + tiny JS (front repo pattern, `PORTAL_DATA`).

### Deliverables

- `build-notify.json` (severity map + routing table + escalation policy) in `9_others` SoT.
- Broker module + producers refactored to emit events.
- `status.json` writer in reports + a front project for the page.
- **Tester:** feed synthetic events → assert routing/dedup/escalation transitions (pure-function table test, no network).

---

## 5. Sequencing & dependencies

```
Phase 0 (bug fixes) ──┬─> Phase 1 (tiers)  ─┬─> Phase 3 needs T0/T2 events + history
                      ├─> Phase 2 (VMs)     ─┘
                      └─> Phase 3 broker (can start in parallel; producers land as P0/P1/P2 refactor)
```

- **Phase 0 first** — low-risk, reversible, unblocks trustworthy signal. (Fixes R1/R7 kill the false-RED immediately.)
- **Phase 1 & 2 parallel** — different files, different repos.
- **Phase 3 broker** can be built in parallel; producers (load-shedder, journal-ntfy, reports) switch to it as each phase touches them.
- Nothing builds on termux. X86 → GHA, ARM → oci-apps builder. Validate via commit+push → ship.yml.

## 6. What I deliberately did NOT propose (YAGNI)

- No Prometheus/Grafana/InfluxDB — JSONL ring + status page covers trend needs at ~zero cost. Add a TSDB only if querying gets painful.
- No new notification transport service — ntfy + Matrix + email already exist; we route, not rebuild.
- No rewrite of `reports-common` — the shared modules are the foundation; we extend.
- No blanket container auto-restart — only scoped tier-1 healing with circuit breaker.

---

## 7. Approval gate

Confirm and I'll start **Phase 0** (the 15 concrete bug fixes in §1), each as a small commit with its tester. Phases 1-3 get their own sub-plans as we reach them.
