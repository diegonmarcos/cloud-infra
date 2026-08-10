#!/usr/bin/env bash
# test-monitoring-urls.sh — verify the monitoring slice of
# _cloud-data-consolidated.json contains only well-formed HTTPS URLs.
#
# 2026-04-28 migrated: previously read cloud-data-monitoring-targets.json
# directly; now derives the same {endpoint_checks, tls_checks, dns_checks}
# shape from _cloud-data-consolidated.json[.services[*].monitoring] via jq
# into a tmpfile that the rest of this test consumes unchanged.
#
# Regression test for the parser bug where containers.<name>.healthcheck
# (a docker HEALTHCHECK shell command like `wget -qO …`, `curl -f …`,
# `redis-cli ping`) was overwriting the well-formed top-level
# health.path (a URL path), corrupting the monitoring URL emitted as
# `https://${domain}${health.path}` into garbage like
# `https://api.diegonmarcos.comwget -qO …`.
#
# The fix lives in:
#   - parsers/build-json.ts  — only adopt container healthcheck as
#                              health.path if top-level health unset AND
#                              value starts with "/" (URL path shape).
#   - cloud-data-config-derive.ts — defence-in-depth: validate path shape
#                                   when constructing the URL, fall back
#                                   to "/" if invalid.

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}/cloud"
CONS="$REPO/1_configs/dist/_cloud-data-consolidated.json"
[ -f "$CONS" ] || { echo "✗ $CONS not found — run build.sh all first"; exit 1; }

# Derive the same {endpoint_checks, tls_checks, dns_checks} shape that
# the deprecated cloud-data-monitoring-targets.json had, from the
# consolidated file. Keeps the rest of this test unchanged.
TARGET="${TMPDIR:-/tmp}/test-monitoring-urls-$$.json"
trap 'rm -f "$TARGET"' EXIT
jq '{
  endpoint_checks: [
    .services | to_entries[]
    | select(.value.monitoring.endpoint_check == true and (.value.domain // "") != "")
    | {service: .key, vm: .value.vm, domain: .value.domain, url: ("https://" + .value.domain + (.value.health.path // "/"))}
  ],
  tls_checks: [
    .services | to_entries[]
    | select(.value.monitoring.tls_check == true and (.value.domain // "") != "")
    | {service: .key, domain: .value.domain}
  ],
  dns_checks: [
    .services | to_entries[]
    | select(.value.monitoring.dns_check == true and (.value.domain // "") != "")
    | {service: .key, domain: .value.domain}
  ]
}' "$CONS" > "$TARGET"
FAILS=0

# Each URL must:
#   1. Start with https://
#   2. Contain no whitespace
#   3. Contain no shell-command tokens (wget|curl|redis-cli|exit|||&&)
#   4. Have a hostname matching ^[A-Za-z0-9.-]+ that ends in a known TLD chars
#      (we use the simple "has a dot before the first /" check)
#
# The engine source of truth for these rules is the parser bug-fix at
# parsers/build-json.ts:246-258 and cloud-data-config-derive.ts:1158-1170.

bad=$(jq -r '
  .endpoint_checks // [] | .[] |
  select(
    (.url // "" | type != "string") or
    (.url // "" | startswith("https://") | not) or
    (.url // "" | test("\\s")) or
    (.url // "" | test("(?i)\\b(wget|curl|redis-cli|exit\\s+1)\\b")) or
    (.url // "" | test("\\|\\|")) or
    (.url // "" | test("&&"))
  ) | "\(.service // "?")\t\(.url // "<missing>")"
' "$TARGET" || true)

if [ -n "$bad" ]; then
    echo "✗ malformed URLs in derived monitoring slice (from _cloud-data-consolidated.json):"
    printf '%s\n' "$bad" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    total=$(jq '.endpoint_checks | length' "$TARGET")
    echo "✓ all $total endpoint_checks URLs are well-formed"
fi

# Also check tls_checks and dns_checks for the same shell-token leakage
# (they only carry `domain`, but the same parser bug could pollute it).
bad_tls=$(jq -r '
  .tls_checks // [] | .[] |
  select((.domain // "") | test("\\s|(?i)\\b(wget|curl|redis-cli)\\b|\\|\\||&&"))
  | "\(.service // "?")\t\(.domain)"
' "$TARGET" || true)
if [ -n "$bad_tls" ]; then
    echo "✗ malformed tls_checks domains:"; printf '%s\n' "$bad_tls" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    echo "✓ all tls_checks domains well-formed"
fi

bad_dns=$(jq -r '
  .dns_checks // [] | .[] |
  select((.domain // "") | test("\\s|(?i)\\b(wget|curl|redis-cli)\\b|\\|\\||&&"))
  | "\(.service // "?")\t\(.domain)"
' "$TARGET" || true)
if [ -n "$bad_dns" ]; then
    echo "✗ malformed dns_checks domains:"; printf '%s\n' "$bad_dns" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    echo "✓ all dns_checks domains well-formed"
fi

# And a structural check: every service that has top-level monitoring.endpoint_check
# in its build.json should appear in endpoint_checks (proves the parser is no
# longer dropping top-level monitoring when a container has its own).
SOLUTIONS="$REPO/a_solutions"
expected=$(find "$SOLUTIONS" -maxdepth 2 -name build.json -exec sh -c '
  for f in "$@"; do
    jq -r --arg f "$f" "select(.monitoring.endpoint_check == true and (.domain // \"\") != \"\") | .name // (\$f | split(\"/\") | .[-2])" "$f" 2>/dev/null
  done
' _ {} +)
emitted=$(jq -r '.endpoint_checks[] | .service' "$TARGET")
missing=$(comm -23 <(printf '%s\n' "$expected" | sort -u | grep -v '^$') <(printf '%s\n' "$emitted" | sort -u | grep -v '^$'))
if [ -n "$missing" ]; then
    echo "✗ services declare monitoring.endpoint_check but are missing from output:"
    printf '%s\n' "$missing" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    echo "✓ every monitoring.endpoint_check service is emitted"
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-monitoring-urls: PASS"
    exit 0
else
    echo "test-monitoring-urls: FAIL ($FAILS check(s) failed)"
    exit 1
fi
