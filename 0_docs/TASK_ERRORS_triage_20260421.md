# TASK — Errors & Engine Bugs Triage (2026-04-21)

> **Source**: `reports/build.sh all` run at 2026-04-21 19:45–19:51 UTC.
> **Input artefacts**: `cloud-data/reports/dist/{cloud_health_full,cloud_mail_full,cloud_sec_data,cloud_sec_network,cloud_url_health,cloud_health_daily}.json`
> **Scope**: every failure ❌/⚠ across all 6 reports — triaged into 3 buckets.

## Report totals

| Report | Total | Crit | Warn | Notes |
|---|---:|---:|---:|---|
| cloud-health-full-2 | 300 | 9 | 20 | 9 crit = 8 containers + 2 drift-missing |
| cloud-health-full-daily | — | — | — | HTML-only, no summary schema |
| cloud-mail-health-full | 87 | 5 | 3 | DKIM + Maddy WG bind + mail-mcp auth |
| cloud-sec-data | 115 | 30 | 55 | 80 repo_findings + 6 journal + 49 runtime |
| cloud-sec-network | 92 | 2 | 19 | 2 WG + port-scan + dns + firewall rogue |
| cloud-url-health | 16/16 pub · 57/74 priv | — | — | 17 priv down |

---

## BUCKET A — REAL INFRA (need remediation) · **13 items**

### A1. Container crashes
| # | Container | VM | Status | Root cause |
|---|---|---|---|---|
| A1.1 | `c3-services-mcp` | oci-apps | Exited (134) 3d ago | SIGABRT — assertion failure |
| A1.2 | `photos-db` | oci-apps | Exited (255) 6h ago | Postgres boot crash — corrupt WAL (consequence of A1.3 failing to checkpoint) |
| A1.3 | `photos-webhook` | oci-apps | Created, never Running | Python dep missing at init |
| A1.4 | `fluent-bit` | oci-analytics | Created, never Running | Classifier config crash on boot |
| A1.5 | `revealmd` | oci-apps | Exited | — (investigate) |
| A1.6 | `kg-graph` | oci-apps | Exited (port 8001 unreachable) | — (investigate) |

**Fix pattern**: `build.sh ship` after dependency/config fix. One per service.

### A2. DNS / mail infra
| # | Issue | Fix |
|---|---|---|
| A2.1 | **DKIM TXT missing** at `dkim._domainkey.diegonmarcos.com` | Add via Terraform (`cloud-data-cloudflare-dns.json` gap — see `project_terraform-clouddata-gap.md`) |
| A2.2 | **Maddy ports not listening on WG 10.0.0.3**: 993/465/587/4190/8443/22000 | Iptables or Maddy bind addresses — `10.0.0.0/24` blocked |
| A2.3 | **Hickory DNS 10.0.0.1 not answering** A-queries | Restart hickory on gcp-proxy; check route for internal zone |
| A2.4 | **mail-mcp SMTP_NO_AUTH** | Set `SMTP_USERNAME`/`SMTP_PASSWORD` in mail-mcp secrets |

### A3. Security
| # | Issue | Detail |
|---|---|---|
| A3.1 | **SSH bruteforce gcp-proxy**: 1572 attempts / 112 IPs | Top: 193.32.162.151 (101×), 120.76.156.133 (78×). fail2ban jail not catching. |
| A3.2 | **OOM loop gcp-proxy**: `earlyoom.service` killed 3× | Investigate `MemoryMin` for the protection slice |
| A3.3 | **OOM on oci-apps**: 10 kill events in system.slice | Identify which cgroup; likely photos-db or ollama |
| A3.4 | **Systemd failures**: `evidence-collector`, `health-agent` (gcp-proxy); `disk-watchdog`, `unified-monitoring-agent_config_downloader` (oci-apps) | Binaries missing after rebuild — redeploy modules |
| A3.5 | **3 creds in git history** | OCI S3 access key (8 commits), C3_BEARER_TOKEN (2), C3_API_KEY (1) — see `project_secrets_remediation.md` + history rewrite plan |

### A4. Topology drift
| # | Issue | Services |
|---|---|---|
| A4.1 | **Unmanaged on gcp-proxy** (running, not declared) | `vaultwarden`, `syslog-bridge`, `github-rss`, `ntfy` |
| A4.2 | **Declared but missing** | `syslog-forwarder` (oci-mail), `cloud-builder-x` (oci-apps, on-demand) |

---

## BUCKET B — ENGINE BUGS (fix in reports/*) · **12 items**

| # | Report | Bug | Suggested fix |
|---|---|---|---|
| B1 | sec-network | `ext:port-scan` probes WG-only ports externally (false FAIL) | Respect `public: false` from container spec; only probe public ports externally |
| B2 | sec-network | MX/SPF/DMARC run on all subdomains (`webmail.*`, `mail-stalwart.*` flagged) | Only run on domains declared as mail hosts in cloud-data |
| B3 | sec-network | `firewall:*:rogue` ignores nftables rules | Cross-reference `ss -lntp` output with actual firewall rules, not just 0.0.0.0 binding |
| B4 | sec-network | `wg:peer-1 handshake 534071s` flagged Critical (laptop peer, expected) | Distinguish `role: vm` from `role: mobile/laptop` peers; only alarm on VMs |
| B5 | health-full-2 | `umami-setup` one-shot flagged as Exited failure | Mark init/one-shot containers in cloud-data; engine skips them |
| B6 | health-full-2 | `webmail.* 302 → auth.` flagged Warning | 302 to configured Authelia host = PASS |
| B7 | health-full-2 | Cross `umami`: correlates to umami-setup one-shot, not umami app | Match container by main-process role, not first-in-compose |
| B8 | url-health | Caddy WG root `/` probe expects 200 | Accept 4xx from reverse proxy with no default site |
| B9 | url-health | `code-server:8443` probed at WG IP (cert SAN mismatch) | Probe via declared hostname, not WG IP |
| B10 | sec-data | journal `ssh_bruteforce` threshold-less | Data-driven threshold in `cloud-data-sec-scan.json` |
| B11 | sec-data | runtime `host_network` blanket warnings | Allowlist in cloud-data: services for which host-network is intentional |
| B12 | health-full-2 drift | 51× `no-port-in-build` (ports.app missing in build.json) | Per `project_port-enforcement-shared-lib.md` — waiting on migration |

---

## BUCKET C — INFORMATIONAL (not errors) · ~150

- 20× `no-domain` drift (MCP-only services legitimately have no public domain)
- 200× threat_intel entries (reputation feed ingestion, not failures)
- 46× docker_event on oci-apps (normal compose traffic)
- Most `host_network` warnings (intentional for dns/mcps/lgtm)
- All 57/74 private url successes (normal)

---

## Prioritization

```
P0 (act this week): A1 (crashes), A2.1 (DKIM), A3.1 (bruteforce), A3.5 (history rewrite)
P1 (next sprint):   A2.2 (Maddy WG), A3.2-3.4 (OOM + systemd), A4 (drift)
P2 (when touching reports): B1-B12 (engine bugs — each 1-line fix once scoped)
P3:                 C (informational, nothing to do)
```

## Testers (fire rule #4)

After each remediation, re-run:
```
sh ~/git/cloud-data/reports/build.sh all
```
Expected trajectory after A-bucket complete:
- cloud-health-full-2 crit 9 → ≤2 (gcp-t4 expected + cloud-builder-x on-demand)
- cloud-mail-full crit 5 → 0
- cloud-sec-data crit 30 → ≤5
- cloud-sec-network crit 2 → 0 (after A3.1 bruteforce mitigated + B4 engine fix)
- cloud-url-health priv 57/74 → ≥65/74 (remaining = intentional SSH/transfer ports)

After B-bucket complete: noise floor drops an additional ~25 warnings across reports.

## Cross-references

- `project_secrets_remediation.md` — P0 credential rotation + history rewrite
- `project_terraform-clouddata-gap.md` — DKIM + other DNS records missing from declarative source
- `project_port-enforcement-shared-lib.md` — B12 parent work
- `project_fix-bugs-immediately.md` — fire rule: engine bugs in B are unshippable until fixed
