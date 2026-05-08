# Collapse public surface to `443/tcp` + `443/udp` + `51820/udp`

**Status**: Phases 1, 2a, 4 done (source-only, undeployed) · Phases 2b, 3, 5 deferred · **Owner**: diego · **Created**: 2026-05-08

## Goal

Reduce gcp-proxy public surface from 11 ports to 3:
- `443/tcp` — Caddy HTTPS + caddy-l4 SNI multiplex (HTTPS + IMAPS/SMTPS over SNI)
- `443/udp` — WireGuard fallback (nftables redirect → 51820), for restrictive networks
- `51820/udp` — WireGuard primary

All other VMs (oci-*) stay at `51820/udp` only.

## Phasing

| # | Title | Risk | Status |
|---|---|---|---|
| 1 | Drop 587 (mail submission) | low | **done** (`53b12b134`) |
| 2a | Caddy global DNS-01 (port 80 still open) | medium | **done** (`5ad8b48b8`); needs deploy + renewal validation |
| 2b | Drop port 80 | low (after 2a validated) | deferred |
| 3 | caddy-l4 SNI multiplex mail-over-TLS onto 443 | medium-high | deferred — see rationale below |
| 4 | WG fallback on 443/udp + drop QUIC | medium | **done** (this commit) |
| 5 | Drop port 25 | high | deferred — needs CF Email Routing rule audit (see rationale) |

Each phase = one commit, individually deployable & reversible.

## Deferred phases — rationale

### Phase 3 deferred — SNI architecture decision needed
Multiplexing IMAPS (993) and SMTPS (465) onto a single port via SNI requires
each protocol to have a distinct SNI hostname (or fragile ALPN matching).
Real options:
1. **Subprotocol subdomains** (cleanest): `imap.diegonmarcos.com:443`,
   `smtps.diegonmarcos.com:443`, `imap-stalwart.diegonmarcos.com:443`,
   `smtps-stalwart.diegonmarcos.com:443`. Requires new DNS CNAMEs +
   updated mail-client docs.
2. **ALPN matchers** (fragile): IMAPS/SMTPS clients rarely advertise ALPN;
   matching on absence-of-ALPN is brittle.
3. **Status quo** (no Phase 3): keep 465, 993, 2443, 2465, 2993 as
   dedicated TCP ports. Public surface stays at 8 ports instead of 3.

Decide #1 vs #3 and ship as a follow-up. Source-side cost is ~30 lines in
`caddyfile.nix` + a few new entries in `cloud-data-cloudflare-dns.json`.

### Phase 5 deferred — CF Email Routing rule coverage
Verified via `c_vps/ba-clo_cloudflare/src/terraform.json`:
- `email_routing.rules[]` has ONE rule covering only `me@diegonmarcos.com`
- All other addresses (`no-reply@`, `postmaster@`, `contact@`, etc.) fall
  through to either the `backup_email` (live.com) or — if MX still points
  at oci-mail:25 — to Maddy directly.

Dropping port 25 without first adding CF Email Routing rules for all
inbound aliases would silently lose mail to non-`me@` addresses. Phase 5
needs an operational pre-step:
1. Inventory all inbound aliases used by the system (Authelia notifications,
   service alerts, etc.)
2. Add CF Email Routing rules for each (or a catch-all → worker)
3. Validate one-week mail flow
4. Then drop port 25

## Final state

| Public port | Purpose |
|---|---|
| `443/tcp` | Caddy HTTPS + caddy-l4 SNI multiplex (HTTPS + IMAPS/SMTPS via SNI) |
| `443/udp` | WireGuard fallback (nftables redirect → 51820) |
| `51820/udp` | WireGuard primary |

Everything else: wg0 only.

## Phase details

### Phase 1 — Drop port 587 (mail submission)

**Source files**
- `c_vps/vps_gcloud/src/terraform.json` — drop `allow-mail-submission` (587), `allow-stalwart-submit` (2587)
- `b_infra/nixhm-sudo-gcp-proxy/build.json` — drop 587 + 2587 from `firewall.public_ports`
- `a_solutions/aa-sui_tools-maddy/build.json` — drop 587 from `proxy.l4_ports[]` and `containers.app.extra_ports[]`
- `a_solutions/aa-sui_tools-maddy/src/templates/maddy.conf.tpl.tpl` — drop `tcp://@BIND_587@:587 tcp://127.0.0.1:587` from `submission` listener (line 102)
- `a_solutions/aa-sui_tools-stalwart/build.json` — drop 2587 from `proxy.l4_ports[]` and `containers.app.extra_ports[]`
- `a_solutions/aa-sui_tools-stalwart/src/templates/config.toml.tpl` — drop `[server.listener.submission]` block + `[server.listener.submission.tls]` block

**Out of scope**
- Maddy `oci_relay.port = 587` is OUTBOUND (Maddy → OCI Email Delivery via STARTTLS). Kept.
- Stalwart `local_port != 2025` rule (auth gating) — unchanged.

**Test**
- Send outbound mail via 465/SMTPS from a client → external → confirm delivery
- Confirm no mail client of yours still uses 587

### Phase 2 — Caddy DNS-01 (drop port 80)

**Prereqs**
- Verify `bb-sec_caddy-l4-image/Dockerfile` includes `caddy-dns/cloudflare` in xcaddy build args
- Add `CF_API_TOKEN` (DNS:Edit scope only on diegonmarcos.com zone) to `a_solutions/bb-sec_caddy/src/secrets.yaml` via sops

**Source files**
- `a_solutions/bb-sec_caddy/src/caddyfile.nix` — global block: `acme_dns cloudflare {env.CF_API_TOKEN}`
- `a_solutions/bb-sec_caddy/src/compose.nix` — pass `CF_API_TOKEN` env var
- Drop `:80` listener (CF "Always Use HTTPS" already redirects)
- `c_vps/vps_gcloud/src/terraform.json` — drop `allow-http`
- `b_infra/nixhm-sudo-gcp-proxy/build.json` — drop port 80

**Test**
- Force cert renewal; confirm `solver: dns-01` in logs
- Wildcard cert renewal also works (DNS-01 supports `*.diegonmarcos.com`)
- Validate BEFORE drop port 80 — keep 80 open in parallel for one renewal cycle

### Phase 3 — caddy-l4 SNI multiplex mail-over-TLS onto 443

**Source files**
- `a_solutions/bb-sec_caddy/src/caddyfile.nix` — add layer4 SNI matchers:
  - `mail.diegonmarcos.com` → maddy IMAPS/SMTPS via WG
  - `mail-stalwart.diegonmarcos.com` → stalwart 2443/2465/2993 via WG
- Drop public_ports 465, 993, 2443, 2465, 2993 from `nixhm-sudo-gcp-proxy/build.json`
- Drop firewall rules `allow-mail-smtps`, `allow-mail-imaps`, `allow-stalwart-jmap`, `allow-stalwart-imaps`, `allow-stalwart-smtps` from `vps_gcloud/src/terraform.json`
- Update mail client docs: IMAPS = `mail.diegonmarcos.com:443`, SMTPS = same

**Test**
- `openssl s_client -connect mail.diegonmarcos.com:443 -servername mail.diegonmarcos.com` → IMAP banner
- Thunderbird/mutt connect IMAPS on `:443` with SNI → mailbox loads

### Phase 4 — WG fallback on 443/udp (drop QUIC)

**Source files**
- `a_solutions/bb-sec_caddy/src/caddyfile.nix` — disable HTTP/3 (`servers { protocols h1 h2 }`)
- New module: `b_infra/_shared/vm-pilot/src/modules/network/wg-fallback-443.nix` — nftables redirect `udp dport 443 → 51820`, conditional on `vm.network.wg_role = "hub"`
- `b_infra/nixhm-sudo-gcp-proxy/build.json` — change 443/udp `desc: "QUIC"` → `desc: "WireGuard fallback"`, `owned_by: "wireguard"`
- WG client configs (Surface, Termux, gha-runner) in cloud-data: dual endpoint, primary 51820 + fallback 443

**Test**
- `nc -zu gcp-proxy 443 < /dev/null` — UDP/443 reaches WG (handshake byte exchange)
- From a network blocking 51820 → switch endpoint → `wg-quick up wg0` → ping 10.0.0.1
- Caddy still serves HTTPS on TCP/443 (no QUIC, minor latency)

### Phase 5 — Drop port 25 (delegate inbound mail to CF)

**Prereqs**
- Confirm CF Email Routing fully delivers to smtp-proxy (already wired)
- All receiving aliases (me@, no-reply@, etc.) configured in CF dashboard

**Source files**
- Cloudflare DNS via Terraform `c_vps/ba-clo_cloudflare/src/`: MX → CF (likely already done)
- `c_vps/vps_gcloud/src/terraform.json` — drop `allow-mail-smtp` (25)
- `a_solutions/aa-sui_tools-maddy/src/` — Maddy outbound-only (drop port 25 inbound listener)
- `a_solutions/bb-sec_caddy/src/` — drop any remaining L4 25 passthrough

**Test**
- Send mail FROM external (gmail) TO me@diegonmarcos.com → arrives via CF → smtp-proxy → maddy
- `nmap -p25 130.110.251.193 35.226.147.64` → port closed
- Outbound mail unaffected (Maddy uses OCI relay outbound, no public 25)
- Keep 25 open 1 week after CF takes over → monitor logs → then drop
