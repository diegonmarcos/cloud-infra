#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/edge-auth-gate.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# edge-auth-gate.test.sh -- the public edge serves NOTHING anonymously.
#
# Owner rule (2026-10-16): PUBLIC URL = fleet Bearer OR Authelia session cookie.
# Every URL is in exactly ONE tier, declared in ONE list
# (cloud-u-containers infra-sec_caddy/build.json caddy_config.edge_auth):
#   a) private           mesh only, never served by the public edge
#   b) public-protected  `import edge_auth` (the shared gate) -- the default
#   c) public-open       only what edge_auth.public_open / .technical lists, with a reason
#
# This renders nothing and starts nothing: it reads the COMMITTED rendered
# Caddyfiles (infra-sec_caddy and infra-sec_caddy-public dist/configs/Caddyfile,
# kept honest by ship's step_verify_committed_dist) plus the two derived
# build-caddy*.json, via 1_cloud-configs/src/derive/url-exposure.py, and FAILS on:
#   - a site block in no tier (public, but no gate, no mesh guard, not declared open)
#   - a site in two tiers (declared open but gated / mesh-only)
#   - a private (tier a) host served by the public edge
#   - an exemption path rendered into a gate that the list does not declare
#     (or declared but not rendered)
#   - a site-level `redir` next to the gate (redir sorts BEFORE forward_auth, so it
#     would run ungated)
#   - a raw-TLS (mail) passthrough that edge_auth.technical does not declare
#   - a stale a0_docs/url-exposure.md (regenerate: python3 1_cloud-configs/src/derive/url-exposure.py table)
# Live counterpart (post-deploy, hits the network): 9_others/test/edge-auth-probe.sh
set -euo pipefail

# Upward search, not ../.. -- build.sh also renders this file to 9_others/dist/test/.
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
for f in "$ROOT/a_solutions/infra-sec_caddy/dist/configs/Caddyfile" \
         "$ROOT/a_solutions/infra-sec_caddy-public/dist/configs/Caddyfile" \
         "$ROOT/1_cloud-configs/dist/build-caddy.json" \
         "$ROOT/1_cloud-configs/dist/build-caddy-edge.json"; do
  [ -f "$f" ] || { echo "FAIL: missing ${f#$ROOT/} (check out cloud-u-containers into a_solutions and run build.sh all)"; exit 1; }
done
exec python3 -I "$ROOT/1_cloud-configs/src/derive/url-exposure.py" check
