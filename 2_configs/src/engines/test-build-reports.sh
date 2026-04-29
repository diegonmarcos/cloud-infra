#!/usr/bin/env bash
# test-build-reports.sh — verify the new build-reports.json contract.
#
# The cloud-data-*.json convention is being deprecated (those files are
# routed to z_archive/ by targetDirFor() in cloud-data-config-derive.ts).
# Reports must read from a single derived file: build-reports.json.
#
# Asserted invariants:
#   1. cloud/2_configs/dist/build-reports.json exists.
#   2. It contains endpoint_checks, dns_checks, tls_checks, vms arrays.
#   3. Every endpoint URL is well-formed: starts with https://, no
#      whitespace, no shell-token leakage (wget|curl|exit|||&&).
#   4. NO removed services appear (no windmill, postlite, quant-lab-*,
#      alerts-api, fluent-bit, syslog-forwarder, backup-gitea, nocodb,
#      cloudflare standalone). Source of truth: a service appears in
#      build-reports.json ONLY if a_solutions/<svc>/build.json exists.
#   5. Every emitted service has a corresponding active build.json.
#   6. cloud-data/build-reports.json is a relative symlink to
#      cloud/2_configs/dist/build-reports.json — consumers reading the
#      legacy cloud-data/ path land on the live engine output.

set -euo pipefail

REPO="${GIT_BASE:-$HOME/git}/cloud"
CLOUD_DATA="${GIT_BASE:-$HOME/git}/cloud-data"
DIST="$REPO/2_configs/dist/build-reports.json"
SYMLINK="$CLOUD_DATA/build-reports.json"
SOLUTIONS="$REPO/a_solutions"
FAILS=0

# 1. File present
if [ -f "$DIST" ]; then
    echo "✓ $DIST exists"
else
    echo "✗ $DIST missing — run cloud/2_configs/build.sh all"
    exit 1
fi

# 2. Schema present
for k in endpoint_checks dns_checks tls_checks vms; do
    if jq -e --arg k "$k" 'has($k) and (.[$k] | type == "array")' "$DIST" >/dev/null 2>&1; then
        echo "✓ build-reports.json has $k array"
    else
        echo "✗ build-reports.json missing $k array"
        FAILS=$((FAILS + 1))
    fi
done

# 3. URL hygiene
bad=$(jq -r '
    .endpoint_checks // [] | .[] |
    select(
        (.url // "" | startswith("https://") | not) or
        (.url // "" | test("\\s|(?i)\\b(wget|curl|redis-cli|exit\\s+1)\\b|\\|\\||&&"))
    ) | "\(.service)\t\(.url)"
' "$DIST" || true)
if [ -n "$bad" ]; then
    echo "✗ malformed URLs in build-reports.json:"
    printf '%s\n' "$bad" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
else
    echo "✓ all $(jq '.endpoint_checks | length' "$DIST") endpoint URLs are well-formed"
fi

# 4. No removed services (verify by absence: every service in build-reports
#    must have an active a_solutions/<...>/<service>/build.json)
emitted=$(jq -r '.endpoint_checks[] | .service' "$DIST" | sort -u)
missing_svc=""
for svc in $emitted; do
    if ! find "$SOLUTIONS" -maxdepth 2 -type d -name "*${svc}" 2>/dev/null \
         -exec test -f {}/build.json \; -print 2>/dev/null | grep -qv z_archive; then
        # second chance — match on a_solutions/<prefix>_<svc>/build.json
        if ! find "$SOLUTIONS" -maxdepth 2 -name build.json -not -path "*z_archive*" -exec sh -c '
            jq -e --arg s "$1" ".name == \$s" "$0" >/dev/null 2>&1
        ' {} "$svc" \; 2>/dev/null | grep -q .; then
            missing_svc="$missing_svc $svc"
        fi
    fi
done
if [ -n "$missing_svc" ]; then
    echo "✗ services in build-reports.json with NO active build.json:$missing_svc"
    FAILS=$((FAILS + 1))
else
    echo "✓ every emitted service has an active build.json (no ghost entries)"
fi

# 5. Relative symlink in cloud-data/
if [ -L "$SYMLINK" ]; then
    target=$(readlink "$SYMLINK")
    case "$target" in
        /*)
            echo "✗ cloud-data/build-reports.json is an absolute symlink ($target) — must be relative"
            FAILS=$((FAILS + 1))
            ;;
        *)
            resolved=$(readlink -f "$SYMLINK")
            if [ "$resolved" = "$DIST" ]; then
                echo "✓ cloud-data/build-reports.json → $target (resolves to engine dist)"
            else
                echo "✗ cloud-data/build-reports.json resolves to $resolved, expected $DIST"
                FAILS=$((FAILS + 1))
            fi
            ;;
    esac
elif [ -f "$SYMLINK" ]; then
    echo "✗ cloud-data/build-reports.json is a regular file — must be a relative symlink"
    FAILS=$((FAILS + 1))
else
    echo "✗ cloud-data/build-reports.json missing (relative symlink to engine dist)"
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-build-reports: PASS"
    exit 0
else
    echo "test-build-reports: FAIL ($FAILS check(s))"
    exit 1
fi
