# Cloudflare One (Zero Trust): primary edge, Authelia fallback

> **Status**: Phase 1 in progress (tunnel + connector live; Access / Gateway blocked on enabling Zero Trust) | **Updated**: 2026-10-14
> **IaC**: `c_vps/ba-clo_cloudflare/src/zero-trust.tf` + `terraform.json .zero_trust` · connector `a_solutions/infra-net_cloudflared` (repo `cloud-u-containers`) · pilot runner `.github/workflows/cf-zero-trust.yml` → `1_cicd/src/scripts/cloud-cf-zero-trust-pilot.sh`

## 1. Goal

| | Primary (target) | Fallback (always kept) |
|---|---|---|
| Human auth | Cloudflare Access SSO (one-time PIN now, Google next) | Authelia two-factor on gcp-proxy (`auth.diegonmarcos.com`) |
| Machine auth | Access service tokens (`CF-Access-Client-Id` / `CF-Access-Client-Secret`) | Authelia OIDC bearer via introspect-proxy (`10.0.0.1:4182`) |
| Network | Cloudflare Tunnel `fleet-edge` (outbound-only, no open ports) | oci-analytics `caddy-public` L4 SNI mux → gcp-proxy Caddy over `wg-public` |
| Private DNS | Zero Trust Gateway (DNS location `fleet` + override policies, `fleet.internal`) | Hickory `10.0.0.1:53` split-horizon (`diegonmarcos.com`, `.app`, `.db`) |

The owner must never be locked out. Every step below keeps the Authelia path working unchanged, and every Cloudflare-side change has a one-step undo.

## 2. Current state (inventory 2026-10-14)

- **Cloudflare account**: Free Website plan, zone `diegonmarcos.com`. Terraform root `c_vps/ba-clo_cloudflare` uses the **Global API Key** (Super Administrator), held as the GHA secret `CLOUDFLARE_API_KEY` and sops in `src/secrets.yaml`. One scoped token exists: "Caddy DNS-01 ACME (wildcard TLS)" (DNS Write + Zone Read), used by Caddy as `CF_API_TOKEN`.
- **Zero Trust**: **not enabled.** Every Access endpoint returns `access.api.error.not_enabled`, there is no team domain, no IdP and no Access app, and Gateway has no locations or rules. Tunnels work: `smtp-proxy-tunnel` (90b644ed…) exists, but its status is *down* with 0 connectors, so `smtp-proxy.diegonmarcos.com` ingress is dead config and a clean-up candidate.
- **DNS**: 49 records. The only proxied record is `mta-sts`. `*` is DNS-only → oci-analytics (`129.151.228.66`, public edge). No RFC1918 address ever goes into public DNS (repo rule).
- **Edge**: oci-analytics `caddy-public` (L4 SNI mux) → gcp-proxy Caddy (`caddy-l4`, TLS via Cloudflare DNS-01) → apps over WireGuard `10.0.0.0/24`. Authelia `forward_auth` (`/api/authz/forward-auth`, default policy `two_factor`) covers browsers. Introspect-proxy covers bearer tokens. Many vhosts also carry a WG-only gate (`@not_wg → 403`).
- **Mesh**: WireGuard hub gcp-proxy `10.0.0.1`. Peers: oci-mail `.3`, oci-analytics `.4`, oci-apps `.6`, plus devices.
- **Fleet DNS**: VMs use `10.0.0.1` (Hickory), then `1.1.1.1`, then `8.8.8.8`. Hickory is authoritative for `diegonmarcos.com` (wildcard → `10.0.0.1`), `app` and `db`, and forwards everything else to 1.1.1.1 / 8.8.8.8.
- **Terraform drift**: the cloudflare root carries a perpetual in-place diff on the 3 SRV records (`srv_imaps`, `srv_jmap`, `srv_submissions`). It predates this work, and the pilot runner never applies it.

## 3. Architecture

```
                         ┌──────────── Cloudflare edge ─────────────┐
 browser ──https──►      │ Access app (SSO: OTP / Google)           │
 machine ──https+hdrs──► │ Access app (service token, 401 on fail)  │──► tunnel fleet-edge
                         └──────────────────────────────────────────┘          │ (outbound QUIC/HTTP2
                                                                                │  from the connectors)
                                     cloudflared @ oci-apps (+ replicas later) ◄┘
                                                │ origin = WG-mesh address (10.0.0.x:port)
                                                ▼
                                          app container

 FALLBACK (unchanged):  client ─► oci-analytics caddy-public ─► gcp-proxy Caddy ─► Authelia forward_auth ─► app
 FALLBACK (no Cloudflare at all): device on WG ─► Hickory 10.0.0.1 (*.diegonmarcos.com → 10.0.0.1) ─► Caddy + Authelia
```

- **One tunnel for the fleet** (`fleet-edge`, remotely managed, ingress rules in terraform). Connectors run in host network mode, so any WG-mesh origin is reachable. Replicas on more VMs add HA without config changes.
- **Ordering safety**: a tunnel hostname's DNS record `depends_on` its Access application. A hostname is never live without Access in front of it.
- **Defence in depth (phase 2)**: set `origin_request.access { required = true, team_name, aud_tag }` on each ingress rule, so cloudflared itself rejects requests without a valid Access JWT. Apps that need an identity read `Cf-Access-Authenticated-User-Email` (humans) or the JWT `common_name` (service tokens). This mirrors today's Caddy `Remote-User` → user `map` blocks.

## 4. Identity provider

Zero Trust was never enabled, so no IdP exists. Choice:

1. **Phase 1: one-time PIN.** It needs no OAuth client or secret. PIN mail for `me@diegonmarcos.com` arrives through CF Email Routing → worker → Gmail + Stalwart. The policy allows `me@diegonmarcos.com` only.
2. **Phase 2: Google** (the owner creates an OAuth client in Google Cloud and the secret goes into sops) becomes the default button. OTP stays enabled as break-glass.
3. Authelia's own OIDC provider is deliberately **not** used as a Cloudflare IdP. That would make the primary path depend on the fallback.

## 5. Per-service mapping

Legend: **Access**: canonical hostname moves to tunnel + Access in phase 3, and the Authelia route stays at `<app>.direct.diegonmarcos.com` and over WG. **Authelia-only**: stays as is.

| Hostname | Today | Plan | Why |
|---|---|---|---|
| `spec-zt` (new) → cloud-spec `10.0.0.6:3080` | (n/a) | **Access, phase 1 pilot** | Static, read-only. Existing `cloud.diegonmarcos.com/spec/` (Authelia + WG) is untouched |
| `git` (gitea), `chat` (mattermost), `playlist`, `analytics` (matomo/umami/openobserve), `app` (etherpad/filebrowser/hedgedoc), `cloud`, `rss` | Authelia, public | **Access** (phase 3, one at a time) | Browser apps, already public behind Authelia |
| `ide`, `workflows` (dagu), `db` (dbgate), `crowdsec`, `photos`, `sheets`, `send`, `mesh`, `proxy`, `messenger` | Authelia, **WG-only** | **Access opt-in only** | Going behind Access makes them internet-reachable (with SSO). Owner decides per app. Default: stay WG-only |
| `mcp` (all MCP servers), `api` (authenticated paths) | Authelia bearer / session | **Access + service tokens** (phase 4) | Machine clients; `/pub/*` on `api` stays public |
| `webmail`, `cal`, `contacts` | Authelia (+WG) | Authelia-only (for now) | CalDAV/CardDAV/mail clients cannot do interactive Access |
| `vault` (vaultwarden) | WG-only | Authelia/WG-only | Bitwarden apps and extensions cannot do Access. Highest-value target, keep it off the internet |
| `auth` (Authelia) | bypass | **Never behind Access** | It is the fallback IdP |
| `vpn` (wstunnel) | auth none | **Never behind Access** | WireGuard fallback transport (break-glass) |
| `mail`, `imap`, `smtps`, `jmap`, `matrix`, `mta-sts` | protocol-specific | Unchanged | Non-HTTP / federation / RFC-public endpoints |
| `diegonmarcos.com`, `www`, `linktree`, `nexus`, `suite`, `maps` | public gh-pages | Unchanged | Public sites |
| `languagetool` | WG-only, auth none | Unchanged (WARP later) | Phone keyboard over WG |

## 6. Machine clients: token-bearer plan

- **Mechanism**: Access service tokens, sent as the `CF-Access-Client-Id` + `CF-Access-Client-Secret` headers. Apps set `service_auth_401_redirect = true`, so a bad token gets a 401 and never a login page. Policies use `decision = "non_identity"` with `include.service_token`.
- **One token per client class** (terraform `.zero_trust.service_tokens[]`, `duration` 8760h, renewed by re-apply plus export):
  - `zt-pilot-machine`: phase 1 test token.
  - `claude-code-mcp`: Claude Code / agents. The headers are added by the existing `.mcp.json` `headersHelper` (`0_apps/src/claude/mcp-auth-headers.sh`) next to today's Authelia bearer, so either edge works.
  - `ci-gha`: GitHub Actions. GHA secrets `CF_ACCESS_CLIENT_ID/SECRET` are set from sops with `devops_secrets_set`.
  - `cloud-apps`: C3 APIs / dagu calling public hostnames. Mesh-internal calls stay direct over WG and need no token.
  - `android-superapp`: the phone app, when its routes move.
- **Custody**: secrets exist only in sops-encrypted terraform state, plus a sops file per token encrypted to the public age recipient (`c_vps/ba-clo_cloudflare/src/secrets.zt-*.yaml`, `_credentials` per `secrets-schema.md`). The pilot runner masks them in logs.

## 7. DNS plan: why Gateway DNS location + override policies

| Option | Verdict |
|---|---|
| **Gateway DNS location + DNS override policies** | **Chosen.** Free plan, no agent on the VMs, reachable from every VM over DoH/DoT, managed in terraform, central query logs and filtering |
| WARP client on servers + private routes / local-domain fallback | Heavy, and duplicates the WireGuard mesh. Kept for *devices* (phase 5) |
| Cloudflare Internal DNS zones / DNS views | Enterprise only |
| Public records with private IPs | Forbidden by repo rule (topology leak, blackholes public clients) |

- Private names live under **`fleet.internal`** (`.internal` is ICANN-reserved). They never collide with the public zone or its `*` wildcard, and they never leak.
- **Phase 1**: location `fleet` + one override `oci-apps.fleet.internal → 10.0.0.6`, verified by a DoH query from oci-apps to `https://<doh_subdomain>.cloudflare-gateway.com/dns-query`.
- **Phase 2 (fleet-wide, needs go-ahead)**: Hickory's `.` forwarder (today 1.1.1.1 / 8.8.8.8) points at the Gateway location (DoT `<sub>.cloudflare-gateway.com:853`), so all fleet resolution goes through Cloudflare. `resolv.conf` keeps `1.1.1.1` as the second nameserver and Hickory stays authoritative for split-horizon. If Gateway breaks, Hickory falls back to 1.1.1.1. Override policies can be generated from topology (`.app` / `.db` → `fleet.internal`).
- **Phase 5 (devices)**: tunnel private route `10.0.0.0/24` + WARP local-domain fallback (`diegonmarcos.com`, `app`, `db` → `10.0.0.1`). WARP becomes an alternative to WireGuard on the laptop and phone.

## 8. Fallback and lockout prevention

1. **Authelia stays deployed and untouched.** Caddy vhosts, Authelia rules and the introspect-proxy are not modified by any phase up to and including 3.
2. **No Cloudflare at all**: on the WG mesh (UDP 51820, or wstunnel), Hickory resolves every `*.diegonmarcos.com` to `10.0.0.1`, which is Caddy + Authelia directly. This keeps working even if Cloudflare DNS, proxy and Access are all down. Break-glass WG endpoint by IP: `35.226.147.64:51820`.
3. **Cloudflare DNS up, proxy / Access / tunnel down**: every hostname that moves to the tunnel keeps a DNS-only twin `<app>.direct.diegonmarcos.com`. Phase 3 adds a DNS-only `*.direct` record → oci-analytics, a Caddy wildcard cert via DNS-01, and Caddy aliases. That path goes through Caddy + Authelia and never through Cloudflare's proxy.
4. **Flip back**: deleting a tunnel hostname's proxied CNAME lets the DNS-only `*` wildcard catch the name again, so it resolves to the old Caddy + Authelia route. This is one terraform change, or one dashboard click in an emergency.
5. Access is never put in front of `auth`, `vpn` or `*.direct`. Two IdPs (OTP + Google) are kept, plus a break-glass service token for the owner's CLI. The owner keeps Cloudflare account recovery codes offline.

## 9. Rollout

| Phase | Scope | State |
|---|---|---|
| 0 | Inventory, design (this doc), pilot runner | done |
| 1a | Tunnel `fleet-edge` + cloudflared on oci-apps (no public hostname, catch-all 404) | **done** |
| 1b | **Owner enables Zero Trust** → `org_enabled: true` → `[zt:plan]` → `[zt:apply]` → `[zt:verify]`: OTP IdP, `spec-zt` Access app, `zt-pilot-machine` token, Gateway location + `oci-apps.fleet.internal` | blocked on owner |
| 2 | Hardening: Google IdP, origin JWT validation, connector replicas (gcp-proxy, oci-analytics), scoped API token instead of the Global key, health checks in cloud-health, MCP headers helper | needs go-ahead |
| 3 | Move public Authelia hostnames to Access one at a time (+ `*.direct` fallback) | needs go-ahead |
| 4 | Machine clients on service tokens (MCP, CI, cloud apps, Android) | needs go-ahead |
| 5 | Fleet-wide DNS through Gateway; WARP for devices (optional) | needs go-ahead |

**Running a phase**: on the `cf-zero-trust-phase1` branch, push with `[zt:probe|plan|apply|verify|export]` in the commit message. On `main`, run the workflow by hand (`mode` input). `apply` applies **only pure creates of `*.zt_*` addresses** (`-target`) and refuses otherwise. It commits the encrypted state first, then the sops secrets.

## 10. Rollback

- **Pilot app**: delete the `spec-zt` CNAME (dashboard or terraform) and the hostname is gone. Nothing else depends on it. To remove all gated resources, set `org_enabled: false` and run ship-terraform (owner-approved destroy of the `zt_*` Access/Gateway resources).
- **Tunnel**: `devops_service_stop cloudflared` (oci-apps) and the tunnel goes inactive. In phase 1 no production traffic uses it.
- **Everything**: remove `zero-trust.tf` + `.zero_trust`, run ship-terraform, delete `a_solutions/infra-net_cloudflared`. Authelia was never changed, so nothing else needs rolling back.

## 11. Credentials the owner must provide

- **Enable Zero Trust** (blocks phase 1b). This is not an API-scope problem, because the Global key is Super Administrator. Dashboard → *Zero Trust* → choose team name (suggested `diegonmarcos` → `diegonmarcos.cloudflareaccess.com`) → *Free* plan (needs a payment method on file, $0).
- **Recommended (phase 2)**: replace the Global API Key in terraform with a scoped API token:
  - Account: *Cloudflare Tunnel: Edit*, *Access: Apps and Policies: Edit*, *Access: Service Tokens: Edit*, *Access: Organizations, Identity Providers, and Groups: Edit*, *Zero Trust: Edit*, *Email Routing Addresses: Edit*, *Workers Scripts: Edit*, *Account Settings: Read*.
  - Zone `diegonmarcos.com`: *DNS: Edit*, *Zone: Read*, *Zone Settings: Edit*, *Email Routing Rules: Edit*.
