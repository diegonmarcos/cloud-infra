#!/usr/bin/env bash
# Guard for owner decision 31: "first use private if a mesh member, then
# fallback to public using bearer". NO OAuth/DCR.
#
# Every MCP entry in a shipped .mcp.json must be EITHER
#   - a stdio entry running .claude/mcp-connect.mjs (mesh probe -> bearer), or
#   - an http entry that carries an Authorization header.
# A bare http entry has no bearer, so Claude Code falls back to OAuth Dynamic
# Client Registration and dies with "DCR rejected (HTTP 401)" at /register.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
files=("$ROOT/0_apps/src/root/mcp.json")
[ -f "$ROOT/.mcp.json" ] && files+=("$ROOT/.mcp.json")
[ -f "$ROOT/1_cloud-configs/dist/mcp.project.json" ] && files+=("$ROOT/1_cloud-configs/dist/mcp.project.json")
[ -f "$ROOT/0_apps/src/claude/mcp-connect.mjs" ] || { echo "FAIL: 0_apps/src/claude/mcp-connect.mjs missing"; exit 1; }
node -e '
let bad = 0;
for (const f of process.argv.slice(1)) {
  const s = JSON.parse(require("fs").readFileSync(f, "utf8")).mcpServers || {};
  for (const [n, e] of Object.entries(s)) {
    const launcher = e.type === "stdio" && (e.args || []).some(a => /mcp-connect\.mjs$/.test(a));
    const bearer = (e.type === "http" || e.url) && e.headers && /^Bearer /.test(e.headers.Authorization || "");
    if (!launcher && !bearer) { console.log(`FAIL ${f}: ${n} is neither mcp-connect.mjs nor http+Authorization (would fall back to OAuth/DCR)`); bad++; }
  }
}
if (bad) process.exit(1);
console.log("ok: every MCP entry is mesh-first launcher or bearer-carrying http");
' "${files[@]}"
