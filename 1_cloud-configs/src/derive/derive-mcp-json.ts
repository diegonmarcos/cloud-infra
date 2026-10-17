// derive-mcp-json.ts
//
// Emits the project-scoped MCP server registry that Claude Code reads from a
// repo's .mcp.json, derived from the same service declarations everything else
// is derived from.
//
// Why this exists: cloud's .mcp.json was a tracked SYMLINK to
// /home/diego/.mcp.json — a path that exists on exactly one laptop. Every
// clone, every CI runner and every container got a dangling link, and Claude
// Code loads no MCP servers at all when .mcp.json cannot be read. It fails
// silently: no error, no warning, the servers are simply absent. Deriving a
// real file makes every repo self-contained.
//
// Inputs (read-only, single source of truth):
//   - a_solutions/<service>/build.json  ← .mcp (transport, endpoint_path, auth,
//                                          display_name, description)
//                                        .containers.app.proxy (parent_domain,
//                                          base_path, public)
//   - cloud-u-linux da_my-ai/data/claude/mcp-policy.json ← .direct_http, the
//                                          endpoints reached directly at a mesh
//                                          IP (cloud-vault-mcp, cloud-cgc-pvt-mcp)
//                                          rather than through the public proxy.
//                                          No build.json field can express this
//                                          (there is no parent_domain/base_path
//                                          to derive a URL from), so it has to
//                                          come from the policy file instead of
//                                          being silently dropped. gen-mcp-tpl.sh
//                                          (cloud-u-linux) already merges this
//                                          block into mcp.{termux,desktop}.json.tpl;
//                                          this deriver did not, which is why
//                                          dist/mcp.json — and every .mcp.json it
//                                          feeds via deploy-dotfiles.sh — shipped
//                                          two servers short of the tpls.
//
// Output:
//   - 1_cloud-configs/dist/mcp.json     (schema: mcp-servers/v1)
//
// Per fire-rule 6: no hardcoded server list, no hardcoded URLs. Adding an
// `mcp` block to a service's build.json puts it in every repo's .mcp.json on
// the next build.

import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const ENGINE_DIR  = import.meta.dirname!;
const CONFIGS_DIR = path.resolve(ENGINE_DIR, '..', '..');
const CLOUD_ROOT  = process.env.CLOUD_ROOT ?? path.resolve(CONFIGS_DIR, '..');
const DIST_DIR    = path.join(CONFIGS_DIR, 'dist');
const SOLUTIONS   = path.join(CLOUD_ROOT, 'a_solutions');
const OUT_FILE    = path.join(DIST_DIR, 'mcp.json');

// Same override deploy-dotfiles.sh uses for this exact SoT directory — one
// variable relocates every consumer. Defaults to the sibling-checkout layout
// a dev machine's ~/git/ and CI's cloned-next-to-$GITHUB_WORKSPACE both use.
const CLAUDE_SOT   = process.env.CLAUDE_SOT_DIR
  ?? path.join(os.homedir(), 'git', 'cloud-u-linux', 'da_my-ai', 'data', 'claude');
const POLICY_FILE  = path.join(CLAUDE_SOT, 'mcp-policy.json');

type Server = { type: string; url: string; headers?: Record<string, string>; headersHelper?: string };

function main(): void {
  const servers: Record<string, Server> = {};
  const skipped: string[] = [];

  for (const dir of fs.readdirSync(SOLUTIONS).sort()) {
    const bj = path.join(SOLUTIONS, dir, 'build.json');
    if (!fs.existsSync(bj)) continue;

    let d: any;
    try { d = JSON.parse(fs.readFileSync(bj, 'utf8')); } catch { continue; }

    const mcp = d?.mcp;
    if (!mcp) continue;

    // stdio servers run as a local command, not a URL. They cannot be
    // expressed as a shared project-scoped entry (the binary path is
    // machine-specific), so they stay out rather than being emitted broken.
    if (mcp.transport === 'stdio') { skipped.push(`${dir} (stdio)`); continue; }

    const app   = d?.containers?.app ?? {};
    const proxy = app.proxy ?? {};
    if (!app.public || !proxy.parent_domain || !proxy.base_path) {
      skipped.push(`${dir} (not publicly routed)`);
      continue;
    }

    const endpoint = mcp.endpoint_path ?? '/mcp';
    const name = dir.includes('_') ? dir.slice(dir.indexOf('_') + 1) : dir;

    servers[name] = {
      type: 'http',
      url: `https://${proxy.parent_domain}${proxy.base_path}${endpoint}`,
      // proxy.primary.bearer_auth → the endpoint is gated on an Authelia bearer token
      // (Caddy: @wg → @bearer → 403), so Claude Code must present one. The token
      // CANNOT go in this file: .mcp.json is committed verbatim into every repo
      // under cloud. headersHelper runs at connection time and reads it from
      // vault instead, so only the script path is committed.
      //
      // ${CLAUDE_PROJECT_DIR:-.} — the helper ships with the dotfiles module to
      // <repo>/.claude/, and the default keeps it working in contexts that do
      // not set the variable (the helper itself degrades to {} when vault is
      // absent, so an unauthenticated clone still loads the server and gets an
      // honest 403 rather than a broken config).
      // Keyed on proxy.primary.bearer_auth — the SAME flag that makes caddyfile.nix
      // emit the @bearer branch — so the gate and the credential can never
      // diverge. Deliberately NOT .mcp.auth: that field describes the SERVICE's
      // own auth, and cloud-mattermost-mcp already sets it to "bearer" for its own
      // Mattermost token while sitting behind a plain wg_only gate. Keying on it
      // would attach the Authelia token to a server that neither needs nor
      // accepts it.
      //
      // BOTH a static header and the helper, deliberately. Claude Code merges
      // them as { ...headers, ...headersHelper } — the helper WINS when it
      // runs — so this is purely additive layering, not a fallback chain:
      //
      //   vault host (trusted)   helper runs  → fresh token, overrides below
      //   container / web / CI   helper SKIPPED → static header is what ships
      //
      // The helper alone is not enough, and this is the whole reason
      // c3-infra-mcp never autoloaded on the web. headersHelper is a COMMAND,
      // and Claude Code refuses to execute a project-scoped one until the
      // workspace is trusted ("Security: headersHelper for MCP server '<n>'
      // executed before trust is confirmed" — cli.js, gated on
      // scope==='project'||scope==='local'). A web/remote container never
      // persists trust: hasTrustDialogAccepted stays false for the cloned
      // path, so the helper is never invoked, the request goes out bare, and
      // Caddy's @bearer branch 403s. Claude Code then caches the server in
      // mcp-needs-auth-cache.json and reports "needs authorization" — which
      // reads like a broken OAuth flow and is not one. The token, the helper
      // and the gate were all working the entire time.
      //
      // Static headers are NOT trust-gated (no command executes), and .mcp.json
      // IS parsed with expandVars, which expands ${VAR} in `url` and `headers`
      // for http/sse/ws servers. So the secret still never lands in this file —
      // only the variable name does.
      //
      // The :- default is load-bearing. Without a default an unset variable is
      // recorded as a MISSING VAR and the literal '${...}' is left in the
      // header; with it, a machine that has no token sends an empty bearer and
      // gets the same honest 403 the helper's {} produced, instead of a config
      // error that hides the server entirely.
      ...(d?.proxy?.primary?.bearer_auth === true
        ? {
            headers: { Authorization: 'Bearer ${AUTHELIA_BEARER_TOKEN:-}' },
            headersHelper: 'sh "${CLAUDE_PROJECT_DIR:-.}/.claude/mcp-auth-headers.sh"',
          }
        : {}),
    };
  }

  // direct_http entries are already shaped as { type, url } — no proxy, no
  // auth block to attach (they are reached inside the mesh, not through the
  // Authelia-gated public vhost), so they merge in verbatim.
  if (fs.existsSync(POLICY_FILE)) {
    let policy: any;
    try { policy = JSON.parse(fs.readFileSync(POLICY_FILE, 'utf8')); } catch { policy = null; }
    for (const [name, entry] of Object.entries<Server>(policy?.direct_http ?? {})) {
      servers[name] = entry;
    }
  } else {
    skipped.push(`direct_http (policy not found at ${POLICY_FILE} — cloud-u-linux not checked out)`);
  }

  // Private mesh addresses: every MCP in the manifest also gets a
  // `<name>-mesh` entry at https://c3-<container>.app/mcp (url_scheme.mcp_private,
  // derived into build-caddy.json by config-derive, which runs before this).
  // Served as a private_mesh_routes site reachable only over WireGuard, so it
  // carries NO auth headers — mesh membership is the gate.
  const CADDY_FILE = path.join(DIST_DIR, 'build-caddy.json');
  if (fs.existsSync(CADDY_FILE)) {
    let caddy: any;
    try { caddy = JSON.parse(fs.readFileSync(CADDY_FILE, 'utf8')); } catch { caddy = null; }
    for (const m of caddy?.url_scheme?.mcp_private ?? []) {
      if (!m?.container || !/^c3-[a-z0-9][a-z0-9-]*\.app$/.test(m.private ?? '')) continue;
      servers[`${m.container}-mesh`] = { type: 'http', url: `https://${m.private}/mcp` };
    }
  } else {
    skipped.push(`mesh entries (${CADDY_FILE} not derived yet)`);
  }

  const names = Object.keys(servers).sort();
  const out = {
    _warning: 'GENERATED — DO NOT EDIT. Derived from a_solutions/*/build.json .mcp blocks by 1_cloud-configs/src/derive/derive-mcp-json.ts. Edit the service build.json, then run 1_cloud-configs/build.sh derive.',
    _schema: 'mcp-servers/v1',
    _doc: 'Project-scoped MCP servers for Claude Code. In cloud, 9_others/build.sh refreshes src/apps/root/mcp.json from THIS file and deploys it to .mcp.json, so regenerating the derive is enough. In the other repos the copy under 0_apps/src/root/ is propagated by hand — nothing automates that hop, and it is how vault ended up without the cloud-infra-mcp headersHelper while cloud had it. Re-sync after changing this file.',
    _skipped: skipped,
    mcpServers: Object.fromEntries(names.map((n) => [n, servers[n]])),
  };

  fs.mkdirSync(DIST_DIR, { recursive: true });
  fs.writeFileSync(OUT_FILE, JSON.stringify(out, null, 2) + '\n');
  writeProjectMcp(servers);
  console.log(`derive-mcp-json: ${names.length} server(s) → ${OUT_FILE}`);
  if (skipped.length) console.log(`derive-mcp-json: skipped ${skipped.join(', ')}`);
}

// ── dist/mcp.project.json — what every repo's .mcp.json actually is ─────────
//
// OWNER DECISION 31 (2026-10-17): "first use private if a mesh member, then
// fallback to public using bearer". NO OAuth/DCR. A plain `type: http` entry
// has no fallback and, with no bearer, Claude Code falls into Dynamic Client
// Registration and dies on 401 at mcp.diegonmarcos.com/register. So each
// fleet server becomes a stdio entry running .claude/mcp-connect.mjs, which
// probes the mesh url (no auth) and otherwise bridges to the public url with
// `Authorization: Bearer $FLEET_BEARER` (or $AUTHELIA_BEARER_TOKEN, or the
// vault helper). dist/mcp.json above keeps its url shape: gen-mcp-tpl.sh
// (cloud-u-linux) derives the user-level client lists from it.
//
// One exception, cloud-infra-mcp: it stays on its proven http + static bearer
// path as the control-plane lifeline (it is how a broken launcher gets fixed).
// It still carries a bearer, so the guard (test_mcp_json_no_oauth_only.sh)
// accepts it; what the guard rejects is any http entry WITHOUT Authorization.
function writeProjectMcp(servers: Record<string, Server>): void {
  const LIFELINE = new Set(['cloud-infra-mcp']);
  const AUTH_HOST = 'mcp.diegonmarcos.com';
  const meshOf: Record<string, string> = {};
  const project: Record<string, any> = {};
  for (const [n, e] of Object.entries(servers)) {
    if (n.endsWith('-mesh')) meshOf[n.slice(0, -5)] = e.url;
  }
  for (const n of Object.keys(servers).sort()) {
    if (n.endsWith('-mesh')) continue;
    const e = servers[n];
    if (LIFELINE.has(n)) {
      project[n] = { type: 'http', url: e.url, headers: { Authorization: 'Bearer ${AUTHELIA_BEARER_TOKEN:-}' },
                     headersHelper: e.headersHelper ?? 'sh "${CLAUDE_PROJECT_DIR:-.}/.claude/mcp-auth-headers.sh"' };
      continue;
    }
    const isPublic = e.url.startsWith(`https://${AUTH_HOST}/`);
    // direct_http (mesh-IP) servers: the edge serves /<name>/mcp for those it
    // routes (cloud-cgc-pvt-mcp: 200) and 404s the rest (cloud-vault-mcp) —
    // an honest failure, never an OAuth prompt.
    const mesh = isPublic ? meshOf[n] : e.url;
    const pub = isPublic ? e.url : `https://${AUTH_HOST}/${n}/mcp`;
    const args = ['${CLAUDE_PROJECT_DIR:-.}/.claude/mcp-connect.mjs'];
    if (mesh) args.push('--mesh', mesh);
    args.push('--public', pub);
    project[n] = { type: 'stdio', command: 'node', args };
  }
  const out = {
    _warning: 'GENERATED — DO NOT EDIT. Derived by 1_cloud-configs/src/derive/derive-mcp-json.ts (writeProjectMcp) from the same inputs as dist/mcp.json.',
    _schema: 'mcp-servers/v1',
    _doc: 'Owner decision 31: mesh first (no auth), else public https://mcp.diegonmarcos.com/<svc>/mcp with Authorization: Bearer $FLEET_BEARER (fallback $AUTHELIA_BEARER_TOKEN). No OAuth/DCR. Set FLEET_BEARER in the Claude Code cloud environment secrets / your shell. Bridge: .claude/mcp-connect.mjs.',
    mcpServers: project,
  };
  fs.writeFileSync(path.join(DIST_DIR, 'mcp.project.json'), JSON.stringify(out, null, 2) + '\n');
  console.log(`derive-mcp-json: ${Object.keys(project).length} server(s) → dist/mcp.project.json`);
}

main();
