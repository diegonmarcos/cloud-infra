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
//
// Output:
//   - 1_cloud-configs/dist/mcp.json     (schema: mcp-servers/v1)
//
// Per fire-rule 6: no hardcoded server list, no hardcoded URLs. Adding an
// `mcp` block to a service's build.json puts it in every repo's .mcp.json on
// the next build.

import * as fs from 'node:fs';
import * as path from 'node:path';

const ENGINE_DIR  = import.meta.dirname!;
const CONFIGS_DIR = path.resolve(ENGINE_DIR, '..', '..');
const CLOUD_ROOT  = process.env.CLOUD_ROOT ?? path.resolve(CONFIGS_DIR, '..');
const DIST_DIR    = path.join(CONFIGS_DIR, 'dist');
const SOLUTIONS   = path.join(CLOUD_ROOT, 'a_solutions');
const OUT_FILE    = path.join(DIST_DIR, 'mcp.json');

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
  console.log(`derive-mcp-json: ${names.length} server(s) → ${OUT_FILE}`);
  if (skipped.length) console.log(`derive-mcp-json: skipped ${skipped.join(', ')}`);
}

main();
