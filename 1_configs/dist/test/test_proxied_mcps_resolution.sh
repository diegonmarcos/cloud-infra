#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/test/test_proxied_mcps_resolution.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Proxied-MCP resolution tester — every declared child MCP in any  ║
# ║ build.json `proxied_mcps.{children,user,infra}[]` MUST resolve   ║
# ║ to a real (ip, ports.app) pair in the corresponding derived      ║
# ║ build-{container}.json. If a service is renamed or removed,      ║
# ║ this test fails BEFORE deploy — preventing silent proxy outages. ║
# ║                                                                  ║
# ║ Data-driven (FIRE RULE 3): no hardcoded service list.            ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_proxied_mcps_resolution.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 1_configs/src/deploy/test/ and 1_configs/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
DERIVED_DIR="$REPO_ROOT/1_configs/dist"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every proxied_mcps.<bucket>[].service must resolve in derived configs ──"

# Find every build.json that declares proxied_mcps
mapfile -t HUBS < <(find "$REPO_ROOT/a_solutions" -maxdepth 2 -name build.json \
    -not -path "*/z_archive/*" \
    -exec sh -c 'jq -e "has(\"proxied_mcps\")" "$1" >/dev/null 2>&1 && echo "$1"' _ {} \;)

if [ "${#HUBS[@]}" -eq 0 ]; then
  echo "  (no MCP hubs declared proxied_mcps — nothing to test)"
  exit 0
fi

CHECKED=0
for hub_json in "${HUBS[@]}"; do
  hub=$(jq -r '.name' "$hub_json")
  hub_dir=$(basename "$(dirname "$hub_json")")
  derived="$DERIVED_DIR/build-${hub}.json"

  if [ ! -f "$derived" ]; then
    fail "$hub: derived $derived missing — run 1_configs/build.sh"
    continue
  fi

  # All buckets that hold child arrays — current schemes use either
  # .proxied_mcps.children[]  (mail-mcp v1.5+)
  # .proxied_mcps.{infra,user}[]  (c3-services-mcp)
  child_specs=$(jq -c '
    .proxied_mcps as $p
    | ([
        ($p.children   // []),
        ($p.infra      // []),
        ($p.user       // [])
      ] | add)
    | map(select(.service))
    | .[]' "$hub_json")

  if [ -z "$child_specs" ]; then
    fail "$hub: proxied_mcps declared but no children found"
    continue
  fi

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    name=$(echo "$child" | jq -r '.name')
    service=$(echo "$child" | jq -r '.service')
    path=$(echo "$child" | jq -r '.path // "/mcp"')

    ip=$(jq -r --arg s "$service" '.services[$s].ip // empty' "$derived")
    port=$(jq -r --arg s "$service" '.services[$s].ports.app // empty' "$derived")

    if [ -z "$ip" ] || [ -z "$port" ]; then
      fail "$hub → $name: service '$service' not resolvable in $derived (ip=$ip, port=$port)"
      continue
    fi

    pass "$hub → $name: http://${ip}:${port}${path}"
    CHECKED=$((CHECKED + 1))
  done <<< "$child_specs"
done

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "Proxied-MCP resolution: PASS ($CHECKED child URLs across ${#HUBS[@]} hubs)"
  exit 0
else
  echo ""
  echo "Proxied-MCP resolution: FAIL"
  exit 1
fi
