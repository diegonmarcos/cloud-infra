# Fleet URL scheme: public vs private names

Status: implemented 2026-10-14. Source of truth: service `build.json` in
cloud-u-containers plus the derive engine in `1_cloud-configs/src/derive/`.
Guard: `1_cloud-configs/src/test/test-url-scheme.sh`.

## The two names

| Kind | Form | Reachable from | Declared in |
|---|---|---|---|
| Public | `{app}.diegonmarcos.com` | Internet, through the public edge (caddy-public on oci-analytics) to the hub Caddy on gcp-proxy | `proxy.primary.domain`; landing in caddy `public_landing.landings` |
| Private | `cloud.{name}.app` | WireGuard mesh only (Hickory `app` zone on 10.0.0.1) | derived: one per routable service (`dns` key) and per HTTP container (first port) |

### Public: auth check with a landing fallback

Every Authelia-gated vhost (`auth: two_factor | one_factor`) now runs this
check before anything else:

1. The request carries an `Authorization` header (any scheme: fleet bearer
   JWT, DAV Basic) or an `authelia_session` cookie: unchanged path. Bearer
   goes to introspect-proxy, the cookie to Authelia `forward_auth`. MCP, API
   and Android clients keep working as before.
2. It carries neither: `302` to the app's landing page,
   `https://diegonmarcos.github.io/c__Cloud/c_<category>/<app>/`, or the
   `c__Cloud/` hub when the service declares no `landing`.
3. Interactive sign-in: `https://{app}.diegonmarcos.com/login` redirects to
   Authelia with `rd` back to the vhost.

Exempt: `auth: none` vhosts (Matrix federation, vault, send, grist, JMAP,
vpn), Authelia itself (`auth.`, `auth: bypass`), ntfy's 3-tier `rss.`,
declared `bypass_paths` and `well_known` paths, SMTP/IMAP (L4, not HTTP),
and path routes on shared hosts (`api.`, `mcp.`, `app.`, `analytics.`,
`cloud.`), which keep their current gates.

Exposure is not widened. On a `wg_only` vhost the redirect sorts before the
mesh 403, so an anonymous off-mesh visitor now sees the landing page instead
of a bare 403, but an off-mesh request *with* a credential still gets 403.
Opening a `wg_only` vhost to off-mesh bearer/session clients is a per-service
owner decision (`wg_only: false` in its build.json).

Config: `infra-sec_caddy/build.json` `caddy_config.public_landing`
(`base_url`, `default_path`, `login_path`, `session_cookie`, `auth_portal`,
and the `landings` map vhost → `c_<category>/<app>`). A service may override
with its own `proxy.primary.landing`. Kept in the caddy declaration so a
landing change ships to Caddy alone, not to every service. Rendered by
`infra-sec_caddy/src/caddyfile.nix` (`landingGateBlock`).

### Private: `cloud.{name}.app`

- DNS: Hickory's `* IN A 10.0.0.1` in the `app` zone already answers every
  `cloud.{name}.app` on the mesh. The `.app` TLD is public, but none of these
  names is registered or declared in Cloudflare, and they resolve only through
  fleet DNS. Direct-dial backends (maddy, stalwart, git-proxy-api) get
  explicit `cloud.*` rows next to their legacy rows.
- Caddy: each name is its own site block (`private_mesh_routes` in
  `build-caddy.json`, `mkPrivateMeshRoute`), internal-CA TLS, gated to
  `wg_cidrs` + docker `172.16.0.0/12` + loopback. wg-public (10.1.0.0/24, the
  public edge) and every public address get 403.
- Names are hostname-safe: `_` in container names becomes `-`.
- `https` upstream containers keep only their legacy canonical alias until a
  per-container TLS policy is declared.

### Deprecation of the old private names

`{name}.app`, `{container}.app`, `{container}-{proto}-{port}.app` and
`{container}-null.app` remain served, unchanged, for one release. Removal
happens in the next release: drop `internal_routes`/`all_app_urls` site
rendering and the legacy Hickory rows, after callers have moved (grep the
fleet for `[a-z0-9-]+\.app`).

### Android APK fleet

The APKs reach the fleet through the public names (bearer or session) and
talk to each other through the IPC mesh, not DNS. No APK serves a `.app`
name today. The reserved form for an APK that exposes a mesh endpoint is
`cloud.{apk-id}.app`, pointing at the device's WireGuard IP from
`superapp-wireguard-profiles.json`. Implementation waits until the in-flight
IPC migration in cloud-u-android lands, so it doesn't collide with it.

## Guards (`test-url-scheme.sh`)

1. Every private name matches `^cloud\.[a-z0-9-]+\.app$` and is unique.
2. Every routable `<name>.app` service has exactly one `cloud.<name>.app`.
3. Every service's public domain is a single `{app}.diegonmarcos.com`.
4. No `cloud.*.app` appears in public vhosts, path routes, gh-pages proxies,
   redirects, the public-edge allowlist (`build-caddy-public.json`) or the
   Cloudflare sources (public DNS).
5. Every gated vhost carries a landing under `public_landing.base_url`.

## Owner actions

- No Cloudflare DNS change is needed: public names are unchanged, and private
  names never go to Cloudflare.
- Zero Trust / Cloudflare Access (cloud-infra PR #36) stays untouched. When it
  is enabled, an Access policy in front of these vhosts would replace the
  landing fallback with its own login, so set Access to bypass for bearer
  clients first.
- Per service: whether to set `wg_only: false` so bearer/session clients can
  reach it from off-mesh.

## Mapping: public names

| Public name | Unauthenticated → | Gate |
|---|---|---|
| `languagetool.diegonmarcos.com` | auth:none, unchanged | mesh-only (403 off-mesh) |
| `git.diegonmarcos.com` | `c__Cloud/c_data-apps/cloud-drive/` | public: bearer or session gets the app, anonymous gets landing |
| `mesh.diegonmarcos.com` | `c__Cloud/c_configs/cloud-c3/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `vpn.diegonmarcos.com` | auth:none, unchanged | public |
| `workflows.diegonmarcos.com` | `c__Cloud/c_configs/cloud-c3/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `db.diegonmarcos.com` | `c__Cloud/c_configs/cloud-c3/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `auth.diegonmarcos.com` | own flow, unchanged | mesh-only (403 off-mesh) |
| `crowdsec.diegonmarcos.com` | `c__Cloud/c_configs/cloud-c3/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `chat.diegonmarcos.com` | `c__Cloud/c_inboxes/cloud-chat/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `webmail.diegonmarcos.com` | `c__Cloud/c_inboxes/cloud-mail/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `matrix.diegonmarcos.com` | auth:none, unchanged | public |
| `messenger.diegonmarcos.com` | `c__Cloud/c_inboxes/cloud-matrix/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `jmap.diegonmarcos.com` | auth:none, unchanged | mesh-only (403 off-mesh) |
| `photos.diegonmarcos.com` | `c__Cloud/c_data-apps/cloud-gallery/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `playlist.diegonmarcos.com` | `c__Cloud/c_data-apps/cloud-media/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `cal.diegonmarcos.com` | `c__Cloud/c_data-apps/cloud-tasks/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `ide.diegonmarcos.com` | `c__Cloud/c_agi/cloud-myterminal/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `contacts.diegonmarcos.com` | `c__Cloud/c_data-apps/cloud-contacts/` | mesh-gated: anonymous gets landing, credential off-mesh gets 403 |
| `sheets.diegonmarcos.com` | auth:none, unchanged | mesh-only (403 off-mesh) |
| `send.diegonmarcos.com` | auth:none, unchanged | mesh-only (403 off-mesh) |
| `vault.diegonmarcos.com` | auth:none, unchanged | mesh-only (403 off-mesh) |
| `api.diegonmarcos.com/c3-infra-api` | path route, unchanged (shared host) | mesh-only |
| `api.diegonmarcos.com/pub` | path route, unchanged (shared host) | public |
| `api.diegonmarcos.com/c3-services-api` | path route, unchanged (shared host) | mesh-only |
| `api.diegonmarcos.com/git` | path route, unchanged (shared host) | public |
| `api.diegonmarcos.com/scrappers` | path route, unchanged (shared host) | public |
| `api.diegonmarcos.com/fin-api` | path route, unchanged (shared host) | mesh-only |
| `cloud.diegonmarcos.com/spec` | path route, unchanged (shared host) | mesh-only |
| `cloud.diegonmarcos.com/probe` | path route, unchanged (shared host) | mesh-only |
| `analytics.diegonmarcos.com/matomo` | path route, unchanged (shared host) | public |
| `analytics.diegonmarcos.com/openobserve` | path route, unchanged (shared host) | public |
| `analytics.diegonmarcos.com/umami` | path route, unchanged (shared host) | public |
| `app.diegonmarcos.com/etherpad` | path route, unchanged (shared host) | mesh-only |
| `app.diegonmarcos.com/filebrowser` | path route, unchanged (shared host) | mesh-only |
| `app.diegonmarcos.com/hedgedoc` | path route, unchanged (shared host) | mesh-only |

## Mapping: private names (old → new)

| Old (alias, one release) | New | Upstream |
|---|---|---|
| `authelia.app` | `cloud.authelia.app` | `172.18.0.3:9091` |
| `c3-infra-api.app` | `cloud.c3-infra-api.app` | `10.0.0.6:8081` |
| `c3-infra-mcp.app` | `cloud.c3-infra-mcp.app` | `10.0.0.6:3100` |
| `c3-public-api.app` | `cloud.c3-public-api.app` | `10.0.0.4:8087` |
| `c3-services-api.app` | `cloud.c3-services-api.app` | `10.0.0.6:8082` |
| `c3-services-mcp.app` | `cloud.c3-services-mcp.app` | `10.0.0.6:3101` |
| `c3-spec.app` | `cloud.c3-spec.app` | `10.0.0.6:3080` |
| `caddy-public.app` | `cloud.caddy-public.app` | `10.0.0.4:443` |
| `caddy.app` | `cloud.caddy.app` | `10.0.0.1:443` |
| `calendar-radicale-http-5232.app` | `cloud.calendar-radicale.app` | `10.0.0.6:5232` |
| `calendar.app` | `cloud.calendar.app` | `10.0.0.6:5232` |
| `cloud-cgc-pub-mcp.app` | `cloud.cloud-cgc-pub-mcp.app` | `10.0.0.6:3105` |
| `cloud-drive-mcp-http-3109.app` | `cloud.cloud-drive-mcp.app` | `10.0.0.6:3109` |
| `cloud-infra-mcp-http-3100.app` | `cloud.cloud-infra-mcp.app` | `10.0.0.6:3100` |
| `cloud-mail-mcp-http-3103.app` | `cloud.cloud-mail-mcp.app` | `10.0.0.6:3103` |
| `cloud-mattermost-mcp-http-3102.app` | `cloud.cloud-mattermost-mcp.app` | `10.0.0.6:3102` |
| `cloud-services-mcp-http-3101.app` | `cloud.cloud-services-mcp.app` | `10.0.0.6:3101` |
| `cloud-spec-http-3080.app` | `cloud.cloud-spec.app` | `10.0.0.6:3080` |
| `cloud-superapp-mcp-http-3110.app` | `cloud.cloud-superapp-mcp.app` | `10.0.0.6:3110` |
| `cloud-webmail-http-3000.app` | `cloud.cloud-webmail.app` | `10.0.0.6:3000` |
| `code-server.app` | `cloud.code-server.app` | `10.0.0.6:8443` |
| `contacts-radicale-http-5233.app` | `cloud.contacts-radicale.app` | `10.0.0.6:5233` |
| `contacts.app` | `cloud.contacts.app` | `10.0.0.6:5233` |
| `continuwuity-http-8008.app` | `cloud.continuwuity.app` | `10.0.0.6:8008` |
| `crowdsec.app` | `cloud.crowdsec.app` | `10.0.0.6:8088` |
| `dagu.app` | `cloud.dagu.app` | `10.0.0.6:8070` |
| `dbgate.app` | `cloud.dbgate.app` | `10.0.0.6:8086` |
| `drive-mcp.app` | `cloud.drive-mcp.app` | `10.0.0.6:3109` |
| `etherpad_app-http-3012.app` | `cloud.etherpad-app.app` | `10.0.0.6:3012` |
| `etherpad.app` | `cloud.etherpad.app` | `10.0.0.6:3012` |
| `filebrowser_app-http-3015.app` | `cloud.filebrowser-app.app` | `10.0.0.6:3015` |
| `filebrowser.app` | `cloud.filebrowser.app` | `10.0.0.6:3015` |
| `fin-api.app` | `cloud.fin-api.app` | `10.0.0.6:8340` |
| `g-personal-mcp.app` | `cloud.g-personal-mcp.app` | `10.0.0.6:3106` |
| `g-workspace-mcp.app` | `cloud.g-workspace-mcp.app` | `10.0.0.6:3104` |
| `git-proxy-api.app` | `cloud.git-proxy-api.app` | `10.0.0.4:8123` |
| `gitea.app` | `cloud.gitea.app` | `10.0.0.6:3002` |
| `google-personal-mcp-http-3106.app` | `cloud.google-personal-mcp.app` | `10.0.0.6:3106` |
| `google-workspace-mcp-http-3104.app` | `cloud.google-workspace-mcp.app` | `10.0.0.6:3104` |
| `grist_app-http-3011.app` | `cloud.grist-app.app` | `10.0.0.6:3011` |
| `grist.app` | `cloud.grist.app` | `10.0.0.6:3011` |
| `hedgedoc_app-http-3018.app` | `cloud.hedgedoc-app.app` | `10.0.0.6:3018` |
| `hedgedoc.app` | `cloud.hedgedoc.app` | `10.0.0.6:3018` |
| `kg-store-pub.app` | `cloud.kg-store-pub.app` | `10.0.0.6:8002` |
| `kg-store.app` | `cloud.kg-store.app` | `10.0.0.6:8001` |
| `mail-mcp.app` | `cloud.mail-mcp.app` | `10.0.0.6:3103` |
| `matomo-hybrid-http-8080.app` | `cloud.matomo-hybrid.app` | `10.0.0.6:8080` |
| `matomo.app` | `cloud.matomo.app` | `10.0.0.6:8080` |
| `matrix-continuwuity.app` | `cloud.matrix-continuwuity.app` | `10.0.0.6:8008` |
| `matrix-element.app` | `cloud.matrix-element.app` | `10.0.0.6:8083` |
| `mattermost-mcp.app` | `cloud.mattermost-mcp.app` | `10.0.0.6:3102` |
| `mattermost.app` | `cloud.mattermost.app` | `10.0.0.6:8065` |
| `news-gdelt.app` | `cloud.news-gdelt.app` | `10.0.0.6:3019` |
| `ntfy.app` | `cloud.ntfy.app` | `10.0.0.6:8090` |
| `openobserve.app` | `cloud.openobserve.app` | `10.0.0.6:5080` |
| `photoprism_app-http-3013.app` | `cloud.photoprism-app.app` | `10.0.0.6:3013` |
| `photoprism.app` | `cloud.photoprism.app` | `10.0.0.6:3013` |
| `playlist-syncer.app` | `cloud.playlist-syncer.app` | `10.0.0.6:8090` |
| `scrappers-api.app` | `cloud.scrappers-api.app` | `10.0.0.6:3020` |
| `send_app-http-3016.app` | `cloud.send-app.app` | `10.0.0.6:3016` |
| `send.app` | `cloud.send.app` | `10.0.0.6:3016` |
| `stalwart.app` | `cloud.stalwart.app` | `10.0.0.3:2443` |
| `superapp-mcp.app` | `cloud.superapp-mcp.app` | `10.0.0.6:3110` |
| `umami.app` | `cloud.umami.app` | `10.0.0.6:3006` |
| `unbound-dns64.app` | `cloud.unbound-dns64.app` | `10.0.0.4:53` |
| `vaultwarden.app` | `cloud.vaultwarden.app` | `10.0.0.6:8880` |
| `webmail.app` | `cloud.webmail.app` | `10.0.0.6:3000` |
| `wireguard-mesh.app` | `cloud.wireguard-mesh.app` | `10.0.0.6:8084` |
