# TASK: Mail behind WireGuard — Phase A (wg0-only) then Phase B (dedicated wg-mail)

> **Implementer**: Sonnet. Ship Phase A first, verify in prod, **then** start Phase B.
> **Non-negotiable rules**: fully declarative, data-driven (`build.json` / `config.json` / `cloud-data-*.json`), engine-only (`build.sh`), every step ends with a tester.
> **Replaces**: `TASK_PLAN-mail-dnat.md` (deleted — was a cleanup of a symptom, not a fix of the exposure).

---

## 0. Why two phases

Phase A removes public exposure of user-facing mail ports while keeping the existing single `wg0` mesh — one set of keys, one routing table, zero new infra. ~80% of the security gain with ~20% of the work.

Phase B upgrades the mesh to a **dedicated `wg-mail` interface** so that a leak of the mail VPN key cannot reach any non-mail VM, and a leak of the infra WG key cannot reach mail. True compartmentalisation. Requires a refactor of the WireGuard module and extra key management.

Phase A MUST ship and run clean for at least one week before Phase B starts.

---

## 1. Ground truth (verified before writing this plan)

| Concern | File | Current state |
|---|---|---|
| gcp-proxy `public_ports[]` | `cloud/config.json` | exposes 7 mail ports (465/587/993/2443/2465/2587/2993) forwarded by Caddy L4 |
| oci-mail `public_ports[]` | `cloud/config.json` | exposes MX 25, CF Worker 8080, Stalwart MX 2025, **plus** all user-facing mail ports redundantly (465/587/993/4190/8443/2465/2587/2993/2443/6190/22000/21027) |
| Maddy listeners | `cloud/a_solutions/aa-sui_tools-maddy/src/templates/maddy.conf.tpl.tpl` | hard-coded `tcp://0.0.0.0:25`, `tls://0.0.0.0:465`, `tls://0.0.0.0:993`, etc. |
| Stalwart listeners | `cloud/a_solutions/aa-sui_tools-stalwart/src/templates/config.toml.tpl` | hard-coded `bind = "[::]:2025"`, `bind = "[::]:2993"`, etc. |
| smtp-proxy listener | `cloud/a_solutions/aa-sui_tools-smtp-proxy/` | audit during implementation — currently public on :8080 |
| Caddy L4 renderer | `cloud/a_solutions/bb-sec_caddy/src/caddyfile.nix` lines 168-189 | `mkL4Section` no-ops when `l4_routes == []` — no Caddy edit needed |
| Derive | `cloud/9_others/src/engine/cloud-data-config-derive.ts` lines ~334-360 | builds `l4_routes[]` by picking mail ports out of gcp-proxy `public_ports[]` via a hardcoded `l4Map` dict. Drop this block once gcp-proxy has no mail ports. |
| Firewall module | `cloud/b_infra/_shared/vm-pilot/src/modules/network/firewall.nix` | owns ALL chains, `iptables -A INPUT -i wg0 -j ACCEPT` already present. |
| WireGuard module | `cloud/b_infra/_shared/vm-pilot/src/modules/network/wireguard.nix` | single-interface. Phase B refactors it to multi-interface. |
| Vault WG keys | `cloud/../vault/A0_keys/providers/wireguard/` | per-VM keys for wg0 |
| Webmail | `aa-sui_snappymail` (oci-apps) | connects to IMAP backend via `10.0.0.3:993` (WG internal already) |

Outbound paths unaffected:
- OCI SMTP relay for outgoing mail — oci-mail egresses on eth0, no inbound public port.

---

# PHASE A — Mail behind wg0

## A.1 Goal

| Port class | Today | After Phase A |
|---|---|---|
| **MX** 25 | public on oci-mail | public on oci-mail (no change — RFC) |
| **CF Worker ingress** 8080 | public on oci-mail | public on oci-mail (no change — Cloudflare has no WG) |
| **Stalwart MX** 2025 | public on oci-mail | public on oci-mail *(only if Stalwart is receiving external MX — see A.7)* |
| **User client ports**: 465, 587, 993, 2443, 2465, 2587, 2993, 4190, 6190, 8443, 22000, 21027 | public on oci-mail **and** public on gcp-proxy (Caddy L4) | WG-only — apps bind to `10.0.0.3` on wg0 |
| Caddy L4 layer4 block | 7 mail routes | auto-empty (data), mapping preserved (code) |

External port scan of oci-mail's public IP and gcp-proxy's public IP for any of the "user client" ports MUST return `filtered`/`closed`.

**Authority on WG-only is the container bind.** Caddy L4 mapping stays declared in the derive engine — if we ever decide to re-expose mail publicly, re-adding the ports to gcp-proxy `public_ports[]` is enough. The `l4Map` dict is infrastructure-as-code for reversibility; deleting it would force a refactor to un-do. Keep it.

## A.2 Design

Two coordinated changes:

1. **`config.json`**: delete user-facing mail ports from `gcp-proxy.public_ports[]` and from `oci-mail.public_ports[]`. Keep only the three M2M ports on oci-mail.
2. **Mail service configs**: parametrise the listener address in Maddy + Stalwart + smtp-proxy templates. Default bind = `10.0.0.3` (oci-mail's wg0 IP). MX/CFW ports keep `0.0.0.0`.

Firewall change: **none**. `firewall.nix` already has `iptables -A INPUT -i wg0 -j ACCEPT` — WG peers will reach any WG-bound listener without new rules. Removing ports from `public_ports[]` automatically removes their INPUT ACCEPT on eth0 (belt). The app binding to `10.0.0.3` (suspenders).

Derive engine change: **none**. The `l4Map` block in `cloud-data-config-derive.ts` stays as-is. Since `l4_routes[]` is derived from `public_ports[]`, removing mail ports from gcp-proxy `public_ports[]` auto-empties `l4_routes[]` for mail. The mapping dict is preserved so a future re-expose is one data edit away.

Caddy change: **none**. Empty `l4_routes[]` → empty `layer4 {}` block → renderer emits nothing.

## A.3 Data model — `bind` field in mail `build.json`

Extend `extra_ports[]` in each mail container with a `bind` key. The Nix flake reads it and templates the listener. Unset = default `0.0.0.0` (backward-compatible).

**`aa-sui_tools-maddy/build.json`** (`containers.maddy.extra_ports[]`):
```jsonc
[
  { "port": 25,   "protocol": "tcp",      "bind": "0.0.0.0",  "desc": "MX" },
  { "port": 465,  "protocol": "tls",      "bind": "10.0.0.3", "desc": "SMTPS" },
  { "port": 587,  "protocol": "starttls", "bind": "10.0.0.3", "desc": "Submission" },
  { "port": 993,  "protocol": "tls",      "bind": "10.0.0.3", "desc": "IMAPS" },
  { "port": 4190, "protocol": "tcp",      "bind": "10.0.0.3", "desc": "ManageSieve" },
  { "port": 8443, "protocol": "tls",      "bind": "10.0.0.3", "desc": "Admin UI" }
]
```

**`aa-sui_tools-stalwart/build.json`** (`containers.stalwart.extra_ports[]`):
```jsonc
[
  { "port": 2025, "protocol": "tcp",      "bind": "TBD",      "desc": "MX (shadow)" },   // see A.7
  { "port": 2465, "protocol": "tls",      "bind": "10.0.0.3", "desc": "SMTPS" },
  { "port": 2587, "protocol": "starttls", "bind": "10.0.0.3", "desc": "Submission" },
  { "port": 2993, "protocol": "tls",      "bind": "10.0.0.3", "desc": "IMAPS" },
  { "port": 6190, "protocol": "tcp",      "bind": "10.0.0.3", "desc": "ManageSieve" },
  { "port": 2443, "protocol": "tls",      "bind": "10.0.0.3", "desc": "JMAP/admin HTTPS" },
  { "port": 8080, "protocol": "tcp",      "bind": "0.0.0.0",  "desc": "CF Worker HTTP ingress (if owned by stalwart)" }
]
```

**`aa-sui_tools-smtp-proxy/build.json`**: audit during implementation. Public ingress port (CF Worker) stays `0.0.0.0`. Any backplane port → `10.0.0.3`.

**The bind value must never be hardcoded in Nix** — always read from `build.json`. Phase B changes it to `10.9.0.3` centrally via cloud-data substitution.

## A.4 Template substitution

**Maddy** — `cloud/a_solutions/aa-sui_tools-maddy/src/templates/maddy.conf.tpl.tpl`:

Replace every hard-coded `0.0.0.0` in a listener directive with a per-port placeholder:

```
smtp tcp://@BIND_25@:25 {
submission tls://@BIND_465@:465 tcp://@BIND_587@:587 {
imap tls://@BIND_993@:993 tcp://@BIND_143@:143 {
```

The flake already iterates templates via `substituteAll` / an awk-style pass (see existing `@DOMAIN@`, `@APP_PORT@` substitutions in stalwart). Add a loop: for each `extra_ports[]` entry with a `bind`, export `BIND_<port>` into the substitution map. If a port has no `bind`, fallback to `0.0.0.0`.

**Stalwart** — `cloud/a_solutions/aa-sui_tools-stalwart/src/templates/config.toml.tpl`:

Replace every `bind = "[::]:PORT"` with `bind = "@BIND_PORT@:PORT"`. Same substitution scheme. Note: stalwart accepts IPv4 literal (`"10.0.0.3:993"`) or IPv6 bracketed — use IPv4 literal when bind is an IPv4 address; keep `[::]` semantics only for explicit dual-stack ports (e.g., MX if you wanted IPv6).

**smtp-proxy**: audit its config format and apply the same pattern.

Rule of thumb: **every listener line in every template must be data-driven from `build.json`**. No literal IP anywhere in a template.

## A.5 Derive engine — no change

`cloud/9_others/src/engine/cloud-data-config-derive.ts` stays as-is. The `l4Map` block is the declared mapping between a gcp-proxy public port and its Caddy L4 upstream. Once mail ports are removed from gcp-proxy `public_ports[]` (§ A.6), `l4Map` has nothing to look up → `l4_routes[]` renders empty → Caddy layer4 is empty.

**Do not delete `l4Map`.** It is the reversibility contract: if mail returns to public-facing, one data edit (re-add the port to `public_ports[]`) restores Caddy L4 routing. Deleting the mapping would turn that data edit into a code+data change.

A later cleanup (out of scope for Phase A) can generalise `l4Map` into a per-port field in `public_ports[]` (e.g., `{"port": 993, "proto": "tcp", "l4_upstream": "oci-mail:993"}`) so the mapping moves from a hardcoded dict into data. That's a refactor, not a delete.

## A.6 config.json edits

```jsonc
// vms.<gcp-proxy-id>.public_ports — delete these seven entries:
// 993, 465, 587, 2443, 2465, 2587, 2993

// vms.<oci-mail-id>.public_ports — delete all except:
[
  { "port": 25,   "proto": "tcp", "desc": "SMTP (Maddy MX)" },
  { "port": 8080, "proto": "tcp", "desc": "SMTP proxy (CF Worker ingress)" },
  // keep 2025 only if Stalwart is an external MX — see A.7
]
```

Deletions are belt-level: the app won't listen on eth0 either way (bind = 10.0.0.3 in build.json), but INPUT-level drop is defence-in-depth.

## A.7 Decision point — Stalwart port 2025 & 8080

Before starting, answer in one sentence in the implementation PR:

- **Is Stalwart receiving external MX on port 2025?** If yes → keep 2025 `bind=0.0.0.0` and public in `oci-mail.public_ports[]`. If Stalwart is fed only by the local smtp-proxy → `bind=10.0.0.3`, drop from public_ports.
- **Does CF Worker POST to 8080 on oci-mail directly, or via a Caddy route on gcp-proxy?** If direct → keep public. If via Caddy → move to `10.0.0.3` and let Caddy reverse-proxy across wg0.

Look in: Cloudflare Worker source (`ba-clo_cloudflare-worker/src/`), maddy routing in `maddy.conf.tpl.tpl`, and stalwart smtp listener handlers.

## A.8 Implementation steps (in order)

1. **Audit** smtp-proxy + answer A.7 two questions in the PR description.
2. Edit `aa-sui_tools-maddy/build.json` — add `bind` to each `extra_ports[]` entry.
3. Edit `aa-sui_tools-stalwart/build.json` — add `bind` to each `extra_ports[]` entry.
4. Edit `aa-sui_tools-smtp-proxy/build.json` — add `bind` to each entry.
5. Edit `maddy.conf.tpl.tpl` — replace `0.0.0.0` with `@BIND_<port>@` in the three listener lines (and any others found).
6. Edit `stalwart/config.toml.tpl` — replace `[::]` in each `bind = "[::]:PORT"` with `@BIND_<port>@`.
7. Edit smtp-proxy template equivalently.
8. Edit `aa-sui_tools-{maddy,stalwart,smtp-proxy}/src/flake.nix` — extend the substitution map to export `BIND_<port>` for each `extra_ports[].bind` entry (fallback `0.0.0.0`).
9. Edit `cloud/config.json` — delete mail ports per A.6. **Do not touch `cloud-data-config-derive.ts`.**
10. Regenerate derived JSONs: `cd /home/diego/git/cloud-infra/9_others && ./build.sh`.
11. Commit + push. GHA deploys in order:
    - `ship-gen-configs.yml` — regenerates cloud-data outputs.
    - `ship-oci-mail.yml` — rebuilds maddy + stalwart + smtp-proxy with new bind addresses.
    - `ship-gcp-proxy.yml` — Caddy re-renders with empty `layer4 {}` (l4Map still present in code, but no input data to map).
    - `home-manager.yml` — updates firewalls (INPUT ACCEPT removed for dropped ports).
12. Verify § A.9. On failure, revert the commit (§ A.10).

Do **not** `ssh vm 'systemctl restart maddy'`, `sed`, `docker compose up`, or any other imperative action on the VM. Engine or nothing.

## A.9 Tests (Phase A)

### A.9.1 Unit — rendered configs (runs before deploy)

Add `cloud/9_others/test/test_mail_bind.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null

# Maddy config must bind user ports to 10.0.0.3
M=../a_solutions/aa-sui_tools-maddy/dist/maddy.conf
grep -E '^\s*submission\b.*://10\.0\.0\.3:465' "$M"
grep -E '^\s*imap\b.*://10\.0\.0\.3:993' "$M"
# MX must stay public
grep -E '^\s*smtp\s+tcp://0\.0\.0\.0:25' "$M"

# Stalwart config must bind user ports to 10.0.0.3
S=../a_solutions/aa-sui_tools-stalwart/dist/config.toml
grep -E 'bind\s*=\s*"10\.0\.0\.3:2993"' "$S"
grep -E 'bind\s*=\s*"10\.0\.0\.3:2465"' "$S"

# Caddy has no mail L4 routes (auto-empty because gcp-proxy public_ports has no mail)
jq -e '.l4_routes | length == 0' ../1_cicd/dist/build-caddy.json

# l4Map code still present — reversibility contract
grep -q 'const l4Map' ../9_others/src/engine/cloud-data-config-derive.ts

echo "[PASS] mail listeners bind to 10.0.0.3; Caddy l4_routes empty; l4Map preserved"
```
Wire into the consolidated test runner (`cloud/9_others/build.sh test` or `9_others` preflight).

### A.9.2 Integration — public surface is closed

From **outside** the WG mesh (LTE/mobile tether or an external VPS), run:
```bash
# Use cloud-infra MCP (obs_debug_vps_*) or a disposable host. No inline ssh one-liners.
nmap -Pn -p 465,587,993,2443,2465,2587,2993,4190,6190,8443 <oci-mail-public-ip>
nmap -Pn -p 465,587,993,2443,2465,2587,2993 <gcp-proxy-public-ip>
```
Expected: every listed port = `filtered` or `closed`. MX 25 + 8080 on oci-mail = `open`.

### A.9.3 Integration — WG peers still work

From a workstation with wg0 up:
```bash
nc -zv 10.0.0.3 993 2465 2587 2993 2443 465 587
# all: succeeded
openssl s_client -connect 10.0.0.3:993 -servername mail.diegonmarcos.com -brief </dev/null
# Cert is oci-mail's Let's Encrypt cert
```

### A.9.4 End-to-end — mail flows
- SnappyMail (oci-apps) → login over IMAP → read inbox (uses `10.0.0.3:993` already, must still work).
- SnappyMail → send → external Gmail inbox.
- External sender → your MX (port 25) → mail arrives in SnappyMail.
- JMAP client hitting `10.0.0.3:2443` (WG only) → reads Stalwart mailboxes.

### A.9.5 Regression
- Non-mail traffic untouched: `curl -sI https://diegonmarcos.com` → HTTP/2.
- Other VMs' firewalls unchanged: diff `dist/.local/share/firewall/firewall.sh` before/after for oci-apps / oci-analytics / gcp-t4 → unchanged.

## A.10 Rollback (Phase A)

Revert the merge commit. GHA re-runs — config.json re-opens ports, build.json `bind` goes back to `0.0.0.0`, templates re-render with public listeners. No stateful data touched.

## A.11 Acceptance checklist

- [ ] `config.json` has no mail ports on gcp-proxy and only `[25, 8080(, 2025?)]` on oci-mail.
- [ ] `build.json` for maddy/stalwart/smtp-proxy has a `bind` per `extra_ports[]` entry.
- [ ] Templates substitute `@BIND_<port>@` for every listener; zero literal IPs.
- [ ] `cloud-data-config-derive.ts` is untouched — `l4Map` block preserved (reversibility contract).
- [ ] `dist/build-caddy.json` → `l4_routes: []` (auto-empty because no mail in gcp-proxy `public_ports[]`).
- [ ] `dist/maddy.conf` shows `10.0.0.3` for user ports, `0.0.0.0` for MX.
- [ ] `dist/stalwart/config.toml` shows `10.0.0.3:PORT` for user ports.
- [ ] All tests in § A.9 pass.
- [ ] No imperative commands on VMs during rollout.

---

# PHASE B — Dedicated `wg-mail` interface

## B.1 Goal

After Phase A, **one set of WG keys** (wg0) protects every peer on the infrastructure mesh. A leak of oci-mail's wg0 key lets an attacker reach oci-apps, oci-analytics, gcp-t4. A leak of oci-apps' wg0 key lets the attacker reach oci-mail.

Phase B splits:
- `wg0` = infrastructure mesh. Peers: gcp-proxy, oci-mail, oci-apps, oci-analytics, gcp-t4. No human devices.
- `wg-mail` = mail access mesh. Peers: gcp-proxy, oci-mail, human devices. Nothing else reachable from wg-mail.

Leak impact after Phase B:
- `wg0` key leak → infra reachable, mail **not** reachable (mail apps don't listen on wg0 anymore).
- `wg-mail` key leak → only mail reachable on oci-mail (everything else is on a different interface with different keys).

## B.2 Data model

New schema in `_cloud-data-consolidated.native.wireguard`:

```jsonc
{
  "interfaces": [
    {
      "name": "wg0",
      "subnet": "10.0.0.0/24",
      "listen_port": 51820,
      "peers": [
        { "name": "gcp-proxy",     "wg_ip": "10.0.0.1", "role": "hub"   },
        { "name": "oci-mail",      "wg_ip": "10.0.0.3", "role": "spoke" },
        { "name": "oci-apps",      "wg_ip": "10.0.0.4", "role": "spoke" },
        { "name": "oci-analytics", "wg_ip": "10.0.0.5", "role": "spoke" },
        { "name": "gcp-t4",        "wg_ip": "10.0.0.6", "role": "spoke" }
      ]
    },
    {
      "name": "wg-mail",
      "subnet": "10.9.0.0/24",
      "listen_port": 51821,
      "peers": [
        { "name": "gcp-proxy",   "wg_ip": "10.9.0.1", "role": "hub"    },
        { "name": "oci-mail",    "wg_ip": "10.9.0.3", "role": "spoke"  },
        { "name": "client-*",    "wg_ip": "10.9.0.100+", "role": "client" }
      ]
    }
  ]
}
```

The existing flat `wireguard.{peers, clients}` keys are deprecated after this change. Derive outputs:
- `cloud-data-home-manager.json.wireguard.interfaces[]` — new shape consumed by `wireguard.nix`.
- Back-compat shim: derive also emits flat keys that point at `interfaces[0]` during the transition window (one release).

## B.3 `wireguard.nix` refactor

`cloud/b_infra/_shared/vm-pilot/src/modules/network/wireguard.nix` changes from single-interface to multi-interface. Per interface in `cloudData.wireguard.interfaces`:
- Render `/etc/wireguard/<name>.conf`.
- Emit a systemd override file for `wg-quick@<name>.service`.
- Apply the interface's MASQUERADE rule (per-interface POSTROUTING).

Peer membership is filtered by VM — only interfaces that have this VM's `ssh_alias` in their `peers[]` get rendered on that host.

## B.4 Key management

New key material in `vault/A0_keys/providers/wireguard/mail/`:
- One keypair per `wg-mail` peer (gcp-proxy, oci-mail, each human device).
- Sops-encrypted. NEVER inline keys anywhere. Never commit plaintext.
- The existing derive pipeline that injects wg0 keys from vault extends to read `mail/` too.

Rotation plan: each mesh rotates independently. When a human device is lost, rotate only that device's `wg-mail` key, re-issue — no impact on wg0 infra.

## B.5 Mail app bind switch

Single edit in three `build.json` files: change every entry currently `bind: "10.0.0.3"` to `bind: "10.9.0.3"` (oci-mail's wg-mail IP). MX/CFW ports stay `0.0.0.0`.

Templates already substitute `@BIND_<port>@` from Phase A — nothing changes in templates.

Firewall: add `iptables -A INPUT -i wg-mail -j ACCEPT` alongside the wg0 line. Remove the wg0 accept as the last step only after every mail flow is verified on wg-mail (safer to leave both ACCEPTed during the transition since nothing is listening on `10.0.0.3:993` anymore anyway).

## B.6 DNS

Two viable shapes:

- **Shared DNS** (simplest): the existing `hickory-dns` on gcp-proxy stays at `10.0.0.1`. Each `wg-mail` peer config lists `DNS = 10.0.0.1` and adds `10.0.0.1/32` to its `AllowedIPs`. A single DNS query out of each mail peer traverses wg-mail → hub → wg0 DNS. Works but the mail-only peer now has visibility of one wg0 IP.
- **Dedicated DNS on wg-mail** (cleanest): run a second hickory instance on `10.9.0.1` reachable only from wg-mail, answering only mail-relevant names (`mail.*`, `imap.*`, `smtp.*`). Human devices get `DNS = 10.9.0.1`, zero wg0 visibility.

Pick the dedicated instance for full isolation; document the choice in the PR.

## B.7 Rollout

1. Ship Phase A, verify in prod for one week.
2. Add `wg-mail` to cloud-data; regenerate; GHA deploys. At this point `wg-mail` is up but mail apps still bind to `10.0.0.3` — mesh is idle.
3. Issue `wg-mail` configs for hub + oci-mail + test client (your laptop). Verify connectivity to oci-mail's `10.9.0.3` from the client.
4. Flip `bind` in the three `build.json` files from `10.0.0.3` to `10.9.0.3`. Ship mail services. Mail now reachable **only** via `wg-mail`.
5. Re-issue the wg-mail profiles to all user devices. Remove those devices from wg0 (if they ever were there).
6. One week later: verify nobody connects mail via wg0 (`conntrack` + maddy/stalwart access logs show only 10.9.0.x source IPs). Then drop the `iptables -A INPUT -i wg0 -j ACCEPT` for mail ports (nothing listening there anyway; it's a safety belt).

## B.8 Tests (Phase B)

### B.8.1 Unit — rendered WG configs
- Each VM's `/etc/wireguard/wg0.conf` still contains all infra peers.
- `oci-mail` and `gcp-proxy` have a `/etc/wireguard/wg-mail.conf` with subnet `10.9.0.0/24`, listen port `51821`.
- No other VM has a `wg-mail.conf`.

### B.8.2 Unit — rendered mail configs
`dist/maddy.conf` and `dist/stalwart/config.toml` bind user ports to `10.9.0.3`, not `10.0.0.3`.

### B.8.3 Integration — compartmentalisation drill
- From a workstation on wg0 only (not wg-mail): `nc -zv 10.0.0.3 993` → **fails** (no listener on 10.0.0.3 anymore).
- From the same workstation on wg-mail: `nc -zv 10.9.0.3 993` → succeeds.
- From oci-apps (wg0 only, no wg-mail key): `nc -zv 10.9.0.3 993` → fails (not a peer on wg-mail).

### B.8.4 Leak simulation (staged, not real)
- Temporarily remove oci-mail's `wg-mail` peer record from the hub's config; apply; verify mail becomes unreachable. Revert.
- Temporarily remove oci-mail's `wg0` peer record; apply; verify infra → oci-mail is unreachable on wg0 but mail via wg-mail still works. Revert.

### B.8.5 End-to-end — mail flows over wg-mail
Repeat A.9.4 golden-path tests, but from a wg-mail-only client.

## B.9 Rollback (Phase B)

Phase B is a two-commit rollout (add wg-mail, flip bind). Rollback = revert the "flip bind" commit; mail binds back to `10.0.0.3`; wg-mail mesh stays up unused until next cleanup. Zero data loss, zero irreversible change.

## B.10 Acceptance checklist

- [ ] `cloud-data-home-manager.json.wireguard.interfaces[]` has both `wg0` and `wg-mail`.
- [ ] `wireguard.nix` iterates `interfaces[]`; no literal `wg0` anywhere.
- [ ] oci-mail + gcp-proxy have two `wg-quick@` units running: `wg0` and `wg-mail`.
- [ ] Mail app binds point at `10.9.0.3`.
- [ ] Every test in § B.8 passes, including the two leak-simulation drills.
- [ ] Keys for wg-mail live in `vault/A0_keys/providers/wireguard/mail/`, sops-encrypted.
- [ ] No wg-mail key ever committed plaintext.
- [ ] Client devices only have wg-mail profile (no wg0 access).

---

## Notes for the implementer

- **Absolute paths everywhere**. `git -C /home/diego/git/cloud-infra ...` — never `cd`.
- **MCP tools for VM checks**: `obs_debug_ssh_exec`, `devops_ssh_check`, `obs_debug_docker_exec`. Never raw ssh + shell one-liners.
- **Secrets**: Phase B adds new key material. Use the sops pipeline — see `feedback_never-hardcode-secrets.md`.
- **No "easy fixes"**: if a Nix substitution looks cumbersome, fix the flake's templating engine; do not hand-edit rendered outputs.
- **No submodule commits**: cloud-data lives in a submodule. Don't stage submodule paths — the auto-sync GHA owns that.
- **Testing discipline**: the checklists are enforced by PR review. A missing test = the PR is not mergeable.
