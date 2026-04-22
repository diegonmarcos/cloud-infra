# PLAN — Full infra fix from reports/build.sh all debug (2026-04-22)

> **Source of issues**: `reports/build.sh all` run on 2026-04-21,
> deep-debugged 2026-04-22 via MCP `obs_debug_*` + `docker_inspect`.
> **Triage doc**: `0_docs/TASK_ERRORS_triage_20260421.md` (buckets A/B/C)
> **Related executed fix**: `A2.5` desktop disk defense (DONE 2026-04-22)
>
> **Goal**: every ❌/⚠ in the next `reports/build.sh all` run maps
> 1:1 to a real infra issue still being worked — zero engine-bug noise,
> zero stale-topology drift, zero false positives.

---

## Legend

| Icon | Meaning |
|---|---|
| ✅ | DONE + verified via tester |
| 🟢 | in progress |
| ⏸ | ready to start, awaiting greenlight |
| ❌ | not started |

Every fix MUST be declarative + data-driven + testable (fire rules 0-4).

---

## PHASE 0 — Pre-flight (done today)

| # | Item | Status |
|---|---|---|
| P0.1 | Disk defense desktop (`cloud-data-disk-protection.json` + nix module + switch) | ✅ |
| P0.2 | 30+ new secret-scan patterns deployed (DB passwords, API keys, auth headers) | ✅ |
| P0.3 | Scan identified 3 real P0 credential leaks (OCI S3, C3_BEARER_TOKEN, C3_API_KEY) + Matomo + stalwart ADMIN_PASSWORD | ✅ |
| P0.4 | reports-logs evidence collector + tag index | ✅ |

---

## PHASE 1 — Real infra fixes (P0-P1, bucket A)

### A1. Container crashes (6 services)

#### A1.1 · `c3-services-mcp` exit 134 — JS heap OOM

**Evidence**: `FATAL ERROR: Ineffective mark-compacts near heap limit`
after thousands of retry lines against 4 unreachable sub-MCPs.

**Declarative fix**:
1. Add to `a_solutions/bc-obs_c3-services-mcp/build.json`:
   ```json
   "retry_state": { "max_entries": 1000, "ttl_minutes": 60 }
   ```
2. Patch `proxy-mcp` code to cap retry-state size (read from build.json via existing config pattern).
3. Investigate WHY sub-MCPs are unreachable (likely the same root cause as H8 — gcp-proxy docker-real wrapper missing), not just mask the symptom.

**Tester**:
- Run `c3-services-mcp` for 1h with sub-MCPs down → `docker stats` RSS stable ≤ 300 MB, no exit 134.

**Order**: after A3.X (docker-real wrapper fixed) — sub-MCPs may come back naturally.

---

#### A1.2 · `fluent-bit` stuck Created — file|dir mount mismatch

**Evidence**: `State.Error: /opt/fluent-bit/parsers.conf ... not a directory`.
Compose mounts a file; host path exists as an auto-created directory.

**Declarative fix**:
1. Verify `a_solutions/bc-obs_fluent-bit/build.json` has `configs.app.fluent-bit.conf` + `configs.app.parsers.conf` declared.
2. Ensure build.sh `configs deploy` action writes BOTH as files to `/opt/fluent-bit/*.conf` before `docker compose up`.
3. On oci-analytics: the existing broken mount must be removed (`rm -rf /opt/fluent-bit && build.sh ship`).

**Tester**:
- `docker inspect fluent-bit | jq .[0].State.Status` → `"running"` within 30s of compose up.
- `curl http://10.0.0.4:2020/` → 200.

---

#### A1.3 · `photos-db` exit 255 — ARCH MISMATCH (amd64 image on arm64 VM)

**Evidence**: `exec format error` on `docker-entrypoint.sh`. Image `ghcr.io/diegonmarcos/photos-webhook-db:latest`, VM arm64.

**Declarative fix**:
1. `a_solutions/aa-sui_photos-webhook/build.json` → add `"platforms": ["linux/amd64","linux/arm64"]`.
2. Build via `cloud-builder-x` (already multi-arch capable per earlier sessions).
3. Push new image tag + re-ship on oci-apps.
4. Before ship: **inspect the existing volume** (`photos-webhook_photos_db_data`). If PG-16 data initialized by amd64 binary, arm64 binary may refuse (rare but possible). If so, snapshot → drop → reinit.

**Tester**:
- `docker exec photos-db pg_isready -U photos_user -d photos` → `accepting connections`.
- Health check in `docker ps` → `healthy`.

#### A1.4 · `photos-webhook` stuck Created — downstream of A1.3

No independent fix. Recovers when A1.3 lands.

---

#### A1.5 · `revealmd` exited

**Evidence**: listed as Exited in drift (no deep debug yet).

**Declarative fix**:
1. Run `reports-logs/build.sh docker` → `cat reports-logs/dist/containers/revealmd/revealmd/{inspect.json,logs.txt}` for root cause.
2. Based on root cause: build.json change OR re-ship.

**Tester**: `curl http://10.0.0.6:3014/` → 200.

---

#### A1.6 · `kg-graph` port 8001 unreachable

**Declarative fix**:
1. Same as A1.5 — collect evidence first.
2. Likely a SurrealDB bind-address issue (host net) or crash.

**Tester**: `curl http://10.0.0.6:8001/health` → 200.

---

### A2. DNS / mail infra

#### A2.1 · DKIM + DMARC TXT records missing

**Evidence**: 3 reports flag `DKIM NOT FOUND`, `DMARC NOT FOUND` at `dkim._domainkey.diegonmarcos.com` + `_dmarc.diegonmarcos.com`.

**Declarative fix**:
1. DKIM value from Maddy: `docker exec maddy cat /data/dkim/diegonmarcos.com.dns` → TXT content.
2. Add to `cloud-data-cloudflare-dns.json` (per `project_terraform-clouddata-gap.md`):
   ```json
   { "name": "dkim._domainkey", "type": "TXT", "value": "<maddy-dkim-pubkey>", "proxied": false },
   { "name": "_dmarc",           "type": "TXT", "value": "v=DMARC1; p=quarantine; rua=mailto:postmaster@diegonmarcos.com", "proxied": false }
   ```
3. `cd a_solutions/ba-clo_cloudflare-dns && ./build.sh ship` (Terraform apply).

**Tester**:
- `dig +short TXT dkim._domainkey.diegonmarcos.com` → returns value.
- `dig +short TXT _dmarc.diegonmarcos.com` → returns value.
- Send test email → recipient shows `dkim=pass`.

---

#### A2.2 · Maddy WG 993/465/587/4190/8443/22000 refused

**Evidence**: `tls: no cipher suite / sig alg` errors from 10.0.0.1 (smtp-proxy on gcp-proxy) hitting Maddy on oci-mail:10.0.0.3. TCP-refused errors on the other ports (web admin, ManageSieve, Syncthing).

**Declarative fix** — split into two sub-issues:
1. **TLS negotiation** — Maddy cert vs smtp-proxy TLS stack:
   - `docker exec maddy openssl x509 -in /data/tls/fullchain.pem -noout -text | grep -E 'Signature Algorithm|DNS:'` → inspect
   - If ECDSA cert: add RSA fallback OR update smtp-proxy TLS config to accept ECDSA sig alg.
   - Change lives in `a_solutions/aa-sui_tools-maddy/build.json` (TLS config) OR `a_solutions/bb-sec_smtp-proxy/build.json`.
2. **Ports not listening** (4190/8443/22000):
   - Maddy admin HTTPS 8443: add to `a_solutions/aa-sui_tools-maddy/src/maddy.conf.tpl` as explicit listener bound to WG IP `10.0.0.3`.
   - ManageSieve 4190: same.
   - Syncthing 22000: declared in topology but Syncthing not publishing over WG — add `STUN_SERVER=wg` env var OR explicit listen address.

**Tester**:
- `openssl s_client -connect 10.0.0.3:993 -servername mail.diegonmarcos.com </dev/null` → cert returned, handshake OK.
- `tcp(10.0.0.3, 4190)` → connects (not refused).
- `nc -zv 10.0.0.3 22000` → open.
- `reports-logs/build.sh tls mail` → all 6 mail endpoints green in `dist/tls/`.

---

#### A2.3 · Hickory DNS 10.0.0.1 not answering

**Evidence**: mail-full-2 `Hickory DNS: FAIL: 10.0.0.1`. cross_check: container up, DNS queries fail.

**Real root cause** (from H8 debug): **gcp-proxy docker-real wrapper missing** — every MCP docker op on gcp-proxy fails. Likely the hickory-dns container ISN'T actually running, but reports can't tell.

**Declarative fix**:
1. This is A3.4. **Fix that first** (restore docker-real wrapper on gcp-proxy via home-manager).
2. Once docker ops work: `obs_debug_docker_logs vm=gcp-proxy container=hickory-dns` → real state.
3. If container down: `build.sh ship` hickory-dns.
4. If up but DNS failing: inspect config (`cloud-data-dns-services.json` declares zones).

**Tester**: `dig +short @10.0.0.1 diegonmarcos.com A` → returns IP.

---

#### A2.4 · mail-mcp `SMTP_NO_AUTH`

**Evidence**: mail-full-2 reports mail-mcp attempting submission without auth.

**Declarative fix**:
1. `a_solutions/aa-sui_mail-mcp/src/secrets.yaml` → add `SMTP_USERNAME: me@diegonmarcos.com`, `SMTP_PASSWORD: ENC[...]` (sops-encrypted).
2. `a_solutions/aa-sui_mail-mcp/src/build.json` → ensure both env vars piped to container.
3. `build.sh ship`.

**Tester**:
- mail-mcp logs: no more `SMTP_NO_AUTH` errors.
- `reports-logs/build.sh mail` → mail-mcp outgoing probe succeeds.

---

### A3. VM-level infra

#### A3.1 · SSH bruteforce on gcp-proxy (1572 attempts / 112 IPs)

**Evidence**: journal alert: `1572 failed SSH attempts from 112 IPs. Top: 193.32.162.151 (101x), 120.76.156.133 (78x)...`.

**Declarative fix**:
1. fail2ban jail config is declared but not catching — verify `cloud-data-system-protection.json`-equivalent for fail2ban (or add one).
2. Update `~/git/cloud/b_infra/home-manager/_shared/modules/` to ship fail2ban with `sshd` jail enabled (`findtime=10m, maxretry=3, bantime=1h`).
3. Cloudflare WAF: GEO-block / IP-block the top 10 offender IPs at edge (via `cloud-data-cloudflare-dns.json` → `firewall_rules[]`).

**Tester**:
- After deploy: `fail2ban-client status sshd` → `Currently banned:` > 0 within 30 min.
- sec-data journal next-run: `ssh_bruteforce` count drops < 50 / scan window.

---

#### A3.2 · earlyoom loop on gcp-proxy (3 kills of earlyoom itself)

**Evidence**: journal: `3 OOM kill events: Stopping earlyoom.service - Early OOM Daemon`.

**Declarative fix**:
1. Root cause: `earlyoom.service` doesn't have `MemoryMin` big enough OR wrong `OOMScoreAdjust`.
2. Check existing nix: `cloud/b_infra/home-manager/_shared/modules/system-protection-scheduler-fifo-rr-cfs.nix` — verify earlyoom has `OOMScoreAdjust=-999` + `MemoryMin=20M`.
3. If missing: add to the module.
4. Re-ship.

**Tester**:
- `systemctl show earlyoom | grep -E 'OOMScoreAdjust|MemoryMin'` → matches expected values.
- 24h no OOM of earlyoom itself (journal has zero `Stopping earlyoom.service`).

---

#### A3.3 · Generic OOM on oci-apps (10 kills in system.slice)

**Evidence**: journal: `10 OOM kill events: system.slice: A process...`.

**Declarative fix**:
1. Inspect which cgroup: `journalctl -k | grep 'oom_reaper'` → look at `comm=`.
2. Likely candidates: photos-db (A1.3 — crashes often), ollama-hai, c3-services-mcp (A1.1).
3. After A1.X fixes, should reduce organically.
4. If continues: tighten `MemoryMax` per offending container in its `build.json`.

**Tester**: After A1 bucket complete, `sec-data journal` count drops < 3 / day.

---

#### A3.4 · disk-watchdog.service failed on oci-apps + gcp-proxy

**Evidence**: 50 systemd failures logged; disk-watchdog among them.

**Declarative fix**:
1. Already exists in `cloud/b_infra/home-manager/_shared/modules/system-protection-watchdog-petter-dropbear-health-agent.nix` but not deployed or binary missing.
2. `cd ~/git/cloud/b_infra/home-manager && ./build.sh ship` — redeploy HM to all 4 VMs.
3. Verify on each VM: `ssh <vm> 'systemctl is-active disk-watchdog.service'` → `active` or `inactive` (for oneshot waiting on timer).
4. **Follow-up refactor** (A2.6): make this module data-driven by reading `cloud-data-disk-protection.json` (same JSON desktop now uses). Separate change, lower priority.

**Tester**:
- After ship: `mcp__cloud-infra-local__obs_debug_vm_status vm=oci-apps` → no `disk-watchdog: Failed to start` in journal.
- Force trigger: `systemctl start disk-watchdog.service` → exit 0.

---

#### A3.5 · Systemd unit failures (evidence-collector, health-agent, disk-watchdog, unified-monitoring-agent_config_downloader)

Bundled with A3.4 — all same root cause: binaries missing after last rebuild. Fix: re-ship home-manager to all VMs.

**Tester**: `systemctl --failed` on each VM → empty list.

---

### A4. Topology drift

#### A4.1 · 4 unmanaged containers on gcp-proxy

**Evidence**: `vaultwarden`, `syslog-bridge`, `github-rss`, `ntfy` running on gcp-proxy but not declared.

**Declarative fix** (choose per service):
- **If keep**: add to `cloud-data-topology.json` with correct VM assignment + port + domain.
- **If retire**: stop container + remove from `/opt/containers/` + document.

My guess from service names: all are actively used → declare them properly. Per-service build.json + topology entry.

**Tester**: After ship, next `reports/build.sh cloud-health-full-2` → zero `Drift unmanaged` entries on gcp-proxy.

---

#### A4.2 · `syslog-forwarder` declared but not deployed (oci-mail)

**Declarative fix**:
- Ask: is syslog-forwarder still needed? (It feeds evidence-collector DAG per project_security-reports-evidence-vault.md.)
- If yes: `cd a_solutions/bc-obs_syslog-forwarder && ./build.sh ship oci-mail`.
- If no: remove from `cloud-data-topology.json`.

**Tester**: `reports/build.sh cloud-health-full-2` → drift shows neither missing nor unmanaged for syslog-forwarder.

---

### A5. Real credential leaks in git history (from repo-scan)

3 real credentials in git history of the (public) `cloud` repo:
- `AWS_ACCESS_KEY_ID: <REDACTED-LEAK-2026-04-21>` (OCI S3, 8 commits)
- `C3_BEARER_TOKEN = "eyJ…"` (JWT, 2 commits)
- `C3_API_KEY = "<REDACTED-LEAK-2026-04-21>"` (1 commit)
- `ADMIN_PASSWORD: <REDACTED-LEAK-2026-04-21>` (stalwart secrets.yaml.new — uncommitted workspace leftover)
- `MYSQL_ROOT_PASSWORD=<REDACTED-LEAK-2026-04-21>` + `MATOMO_DATABASE_PASSWORD=${VAR:-<REDACTED-LEAK-2026-04-21>}` (11 commits)

**Plan**: existing `project_secrets_remediation.md` + plan I drafted earlier (rotate → purge HEAD → `git filter-repo` → force-push → CI gate).

**Status**: plan drafted; execution deferred to dedicated session (high-risk).

---

## PHASE 2 — Engine bugs (bucket B, 12 items)

Fix while touching each respective report. Each is a one-file change.

| # | Report | Fix | Tester |
|---|---|---|---|
| B1 | sec-network | `ext:port-scan` respect `public: false` — don't probe WG-only ports externally | 0 false FAIL for oci-mail closed-port list |
| B2 | sec-network | MX/SPF/DMARC only on declared mail hosts (`mail.*`, `mail-stalwart.*`) | no `No MX records` for webmail.* |
| B3 | sec-network | `firewall:*:rogue` cross-reference nftables, not just `ss -lntp` | rogue-listener count drops from 30+ to ≤ 5 |
| B4 | sec-network | wg peer role-aware (don't alert laptop peer handshake age) | zero `peer-1 handshake 534071s` alerts |
| B5 | health-full-2 | One-shot containers marked in cloud-data, engine skips them | umami-setup not in failures list |
| B6 | health-full-2 | Authelia-protected 302 → PASS | `webmail.*` not in warnings |
| B7 | health-full-2 | cross_check match by main-process role, not first-in-compose | `umami` cross-check correct |
| B8 | url-health | Caddy WG-IP root probe: accept 4xx | `caddy:443` green |
| B9 | url-health | code-server probed via host header, not WG IP | `code-server:8443` green |
| B10 | sec-data journal | Data-driven bruteforce threshold in `cloud-data-sec-scan.json` | configurable N events → severity |
| B11 | sec-data runtime | Allowlist `host_network: intentional` in cloud-data per service | warn count drops 20+ → ≤ 3 |
| B12 | health-full-2 drift | ports.app migration in build.json (existing `project_port-enforcement-shared-lib.md`) | 51× `no-port-in-build` → 0 |

---

## PHASE 3 — Config gaps (bucket C)

| # | Gap | Action |
|---|---|---|
| C1 | 20 services with `no-domain` drift | review per-service; add domain OR flag as intentional (internal MCP) in topology |
| C2 | threat_intel 200 entries | accept as feed context, not errors (config: mark `severity:info` globally for this source) |
| C3 | Docker logging defaults OK (`max-size: 10m, max-file: 3`) | no change — already working |

---

## Execution order

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1 · Unblock infra visibility                          │
├─────────────────────────────────────────────────────────────┤
│  1. A3.4 + A3.5 — Re-ship home-manager to all 4 VMs         │
│     → restores docker-real, disk-watchdog, systemd units    │
│     → unblocks A2.3 (hickory), A1.X debugging, A4.X drift   │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 2 · DNS surface — quick wins                          │
├─────────────────────────────────────────────────────────────┤
│  2. A2.1 DKIM/DMARC Terraform apply (15 min)                │
│     → closes 3 separate report warnings at once             │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 3 · Container crashes — per-service fixes             │
├─────────────────────────────────────────────────────────────┤
│  3a. A1.3 photos-db multi-arch rebuild + ship               │
│  3b. A1.2 fluent-bit parsers.conf deploy fix                │
│  3c. A1.5/A1.6 revealmd / kg-graph evidence-based fixes     │
│  3d. A1.1 c3-services-mcp (may self-heal after STEP 1)      │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 4 · Mail stack                                         │
├─────────────────────────────────────────────────────────────┤
│  4a. A2.2 Maddy TLS cipher/sig-alg + WG bind addresses       │
│  4b. A2.4 mail-mcp SMTP auth                                 │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 5 · Security                                           │
├─────────────────────────────────────────────────────────────┤
│  5a. A3.1 fail2ban jail deploy + Cloudflare WAF rules        │
│  5b. A5 credential rotation + git history rewrite            │
│      (dedicated session — high-risk)                         │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 6 · Topology reconcile                                 │
├─────────────────────────────────────────────────────────────┤
│  6a. A4.1 declare or retire 4 unmanaged on gcp-proxy         │
│  6b. A4.2 syslog-forwarder deploy or retire                  │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 7 · Engine bugs (bucket B, 12 items)                   │
├─────────────────────────────────────────────────────────────┤
│  In parallel while touching each report for other reasons.   │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 8 · Config gaps (bucket C)                             │
├─────────────────────────────────────────────────────────────┤
│  Tag informational findings as severity:info data-drivenly.  │
└─────────────────────────────────────────────────────────────┘
```

---

## Success criteria (end-to-end tester)

After all phases complete, run:
```
sh ~/git/cloud-data/reports/build.sh all
```

Expected output (deltas vs 2026-04-21 baseline):

| Report | Before | After |
|---|---|---|
| cloud-health-full-2 | 300 checks · 9 crit · 22 warn | **≤ 2 crit** (gcp-t4 shutdown + cloud-builder-x on-demand expected) · **≤ 3 warn** |
| cloud-mail-full | 87 · 5 crit · 3 warn | **0 crit · ≤ 1 warn** |
| cloud-sec-data | 324 · 181 crit · 114 warn · 289 repo_findings | **≤ 10 crit** (all real: awaiting history rewrite) · **≤ 20 warn** |
| cloud-sec-network | 92 · 2 crit · 18 warn | **0 crit · ≤ 2 warn** (after B1-B4 engine fixes) |
| cloud-url-health | 16/16 pub · 58/75 priv | **16/16 pub · ≥ 70/75 priv** |

**Invariant**: every remaining ❌/⚠ must map 1:1 to a *real, still-active* infra issue. Zero false positives. Zero engine noise.

---

## Declarative artifacts produced by this plan

| Artifact | Purpose |
|---|---|
| `cloud-data-cloudflare-dns.json` additions (DKIM, DMARC) | A2.1 |
| `cloud-data/a_solutions/bc-obs_c3-services-mcp/build.json` retry-state | A1.1 |
| `cloud-data/a_solutions/aa-sui_photos-webhook/build.json` platforms | A1.3 |
| `cloud-data/a_solutions/aa-sui_mail-mcp/src/secrets.yaml` SMTP_* | A2.4 |
| `cloud-data-sec-scan.json` bruteforce threshold | B10 |
| `cloud-data-topology.json` host_network allowlist per service | B11 |
| `cloud-data-topology.json` reconcile gcp-proxy containers | A4.1 |

Every fix changes a JSON or a build.json — never a script. Fire rule 3 preserved.

---

## Out of scope

- **Bucket B one-shots that touch reports crates** — next reports iteration, bundled with feature work.
- **kg-graph ingestion** (PLAN-kg-ingest.md Phase 2c-2e) — separate plan; Phase 2a+2b are done.
- **Rotating the 3 history-leaked credentials** — dedicated plan already drafted; execution is high-risk, deferred.
- **vm-pilot consolidation** (project_vm-pilot.md) — orthogonal roadmap item.
