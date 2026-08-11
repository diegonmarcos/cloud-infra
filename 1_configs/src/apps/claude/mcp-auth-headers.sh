#!/bin/sh
# Emit MCP connection headers as JSON, for .mcp.json `headersHelper`.
#
# c3-infra-mcp is the one MCP endpoint reachable from off the WireGuard mesh,
# and Caddy gates it on an Authelia-issued bearer token (@wg → @bearer → 403).
# Claude Code therefore needs to present that token, and .mcp.json is committed
# verbatim into every repo under cloud — so the token cannot live in it.
#
# This reads the token at connection time instead. Nothing secret is committed;
# the only thing in .mcp.json is the path to this script.
#
# Claude Code re-runs the helper on a 401/403 and retries once, so rotating the
# token in vault is picked up without restarting the session.
#
# Output contract: a JSON object of string key/value pairs on stdout. `{}` means
# "no headers" — never an error, because a machine without the vault checkout
# should still load the server and get an honest 403 from the gate rather than a
# broken config.
set -eu

# AUTHELIA_OIDC_TOKENS_DIR is already exported by unix's Claude settings
# (da_my-ai/src/data/claude/settings.base.json). The fallback is for shells that
# never sourced it — CI, a container, a fresh machine.
TOKENS_DIR="${AUTHELIA_OIDC_TOKENS_DIR:-$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens}"
TOKEN_FILE="$TOKENS_DIR/claude-admin.json"

[ -r "$TOKEN_FILE" ] || { printf '%s\n' '{}'; exit 0; }

# node, not jq: node is already required by every build.sh in the fleet, jq is
# not guaranteed present. Prints ONLY the header object — the token never
# reaches a log, and a malformed/expired file degrades to {} rather than
# emitting a broken header.
node -e '
const fs = require("fs");
try {
  const t = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).access_token;
  process.stdout.write(t ? JSON.stringify({ Authorization: "Bearer " + t }) : "{}");
} catch { process.stdout.write("{}"); }
' "$TOKEN_FILE" 2>/dev/null || printf '%s\n' '{}'
