#!/usr/bin/env bash
# ── Full cloud health check — runs inside cloud-builder container on GHA ──
# All checks from GHA runner: public URLs, DNS, TLS, SSH reachability, APIs
# Data-driven from cloud-data JSONs (checked out via submodule)
set -uo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

TOPO="I_cloud-data/cloud-data-topology.json"
ROUTES="I_cloud-data/cloud-data-caddy-routes.json"
[ ! -f "$TOPO" ] && echo "ERROR: $TOPO not found" >&2 && exit 1

PASS=0; FAIL=0; WARN=0; TOTAL=0
ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf "  ✓ %s\n" "$*"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); printf "  ✗ %s\n" "$*"; }
warn() { WARN=$((WARN+1)); TOTAL=$((TOTAL+1)); printf "  ⚠ %s\n" "$*"; }

BEARER="${OIDC_TOKEN:-}"

# ═══════════════════════════════════════════════════════════════════════
# L1: VM REACHABILITY — SSH keyscan (no auth, just TCP probe on port 22)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ L1: VM Reachability (SSH keyscan) ═══"

for entry in $(jq -r '.vms | to_entries[] | select(.value.wg_ip) | "\(.value.ssh_alias // .key)|\(.value.wg_ip)"' "$TOPO"); do
  alias="${entry%%|*}"
  wg_ip="${entry##*|}"
  if ssh-keyscan -T 5 "$wg_ip" >/dev/null 2>&1; then
    ok "$alias ($wg_ip) — SSH port open"
  else
    fail "$alias ($wg_ip) — SSH unreachable"
  fi
done

# ═══════════════════════════════════════════════════════════════════════
# L2: PUBLIC URLS — curl all Caddy routes
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ L2: Public URLs ═══"

if [ -f "$ROUTES" ]; then
  # Subdomain routes
  while IFS='|' read -r url auth name; do
    [ -z "$url" ] && continue
    hdr=""
    [ "$auth" != "none" ] && [ -n "$BEARER" ] && hdr="-H Authorization:Bearer $BEARER"
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 $hdr "$url" 2>/dev/null || echo "000")
    if [ "$code" = "000" ] || [ "$code" = "502" ] || [ "$code" = "503" ]; then
      fail "$name — HTTP $code"
    else
      ok "$name — HTTP $code"
    fi
  done < <(jq -r '.routes[]? | select(.domain) | "https://\(.domain)/|\(.auth // "two_factor")|\(.comment // .domain)"' "$ROUTES" 2>/dev/null)

  # Path routes
  while IFS='|' read -r url auth name; do
    [ -z "$url" ] && continue
    hdr=""
    [ "$auth" != "none" ] && [ -n "$BEARER" ] && hdr="-H Authorization:Bearer $BEARER"
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 $hdr "$url" 2>/dev/null || echo "000")
    if [ "$code" = "000" ] || [ "$code" = "502" ] || [ "$code" = "503" ]; then
      fail "$name — HTTP $code"
    else
      ok "$name — HTTP $code"
    fi
  done < <(jq -r '.path_routes[]? | .parent_domain as $p | .paths[]? | select(.upstream) | "https://\($p)\(.base_path)/|\(.auth // "two_factor")|\(.comment // .base_path)"' "$ROUTES" 2>/dev/null)

  # GitHub Pages proxies
  while IFS='|' read -r url name; do
    [ -z "$url" ] && continue
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "000" ] || [ "$code" = "502" ]; then
      fail "$name — HTTP $code"
    else
      ok "$name — HTTP $code"
    fi
  done < <(jq -r '.github_pages_proxies[]? | "https://\(.domain | split(",") | .[0] | gsub("^ +| +$";""))/|\(.comment // .domain)"' "$ROUTES" 2>/dev/null)

  # MCP endpoints (400/405 = healthy, means MCP protocol rejection)
  while IFS='|' read -r url name; do
    [ -z "$url" ] && continue
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "400" ] || [ "$code" = "405" ] || [ "$code" = "406" ]; then
      ok "$name — MCP alive (HTTP $code)"
    elif [ "$code" = "000" ] || [ "$code" = "502" ]; then
      fail "$name — HTTP $code"
    else
      ok "$name — HTTP $code"
    fi
  done < <(jq -r '.mcp_routes[]? | .parent_domain as $p | .endpoints[]? | "https://\($p)\(.base_path)/mcp|\(.base_path)"' "$ROUTES" 2>/dev/null)
fi

# ═══════════════════════════════════════════════════════════════════════
# L3: DNS — check key records exist
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ L3: DNS Records ═══"

DOMAIN=$(jq -r '.owner.domain // "diegonmarcos.com"' "$TOPO" 2>/dev/null || echo "diegonmarcos.com")

for record in "A $DOMAIN" "MX $DOMAIN" "TXT $DOMAIN"; do
  type="${record%% *}"
  name="${record##* }"
  result=$(dig +short "$type" "$name" 2>/dev/null | head -1)
  if [ -n "$result" ]; then
    ok "DNS $type $name → $result"
  else
    fail "DNS $type $name — no record"
  fi
done

# DKIM
dkim=$(dig +short TXT "default._domainkey.$DOMAIN" 2>/dev/null | head -1)
if [ -n "$dkim" ]; then
  ok "DNS DKIM default._domainkey.$DOMAIN — present"
else
  warn "DNS DKIM default._domainkey.$DOMAIN — missing"
fi

# ═══════════════════════════════════════════════════════════════════════
# L4: TLS CERTIFICATES — check expiry on key domains
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ L4: TLS Certificates ═══"

for domain in $(jq -r '.routes[]? | .domain // empty' "$ROUTES" 2>/dev/null | sort -u | head -10); do
  expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
  if [ -n "$expiry" ]; then
    days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if [ "$days_left" -gt 7 ]; then
      ok "$domain — expires in ${days_left}d"
    elif [ "$days_left" -gt 0 ]; then
      warn "$domain — expires in ${days_left}d (renew soon!)"
    else
      fail "$domain — EXPIRED"
    fi
  else
    fail "$domain — TLS connection failed"
  fi
done

# ═══════════════════════════════════════════════════════════════════════
# L5: EXTERNAL SERVICES — GHCR, Cloudflare, GitHub API
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ L5: External Services ═══"

# GHCR
ghcr_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://ghcr.io/v2/" 2>/dev/null || echo "000")
[ "$ghcr_code" = "401" ] || [ "$ghcr_code" = "200" ] && ok "GHCR — reachable ($ghcr_code)" || fail "GHCR — unreachable ($ghcr_code)"

# Cloudflare
cf_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null || echo "000")
[ "$cf_code" = "200" ] && ok "Cloudflare — reachable" || fail "Cloudflare — unreachable ($cf_code)"

# GitHub API
gh_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://api.github.com/zen" 2>/dev/null || echo "000")
[ "$gh_code" = "200" ] && ok "GitHub API — reachable" || fail "GitHub API — unreachable ($gh_code)"

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════"
echo "RESULT: $PASS passed, $FAIL failed, $WARN warnings (of $TOTAL)"
echo "═══════════════════════════════════════════"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
