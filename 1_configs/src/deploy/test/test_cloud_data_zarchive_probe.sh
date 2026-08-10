#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 40 tester — every cloud-data-*.json consumer probes        ║
# ║ dist/z_archive/ as a fallback                                    ║
# ║                                                                  ║
# ║ Audit follow-up (2026-05-05): the derive script (1_configs/      ║
# ║ src/engine/cloud-data-config-derive.ts) intentionally emits     ║
# ║ deprecated `cloud-data-*.json` slices to dist/z_archive/, with   ║
# ║ a top-level comment claiming "Every consumer's path-priority     ║
# ║ chain has been updated to look in z_archive." That update was    ║
# ║ never actually performed for several consumers — they still      ║
# ║ probed only dist/ (top-level) + cloud-data/, silently failing    ║
# ║ to find the file at its current location.                        ║
# ║                                                                  ║
# ║ This test asserts: every script that mentions a deprecated       ║
# ║ cloud-data-{topology|gha-config|dns-services|...}.json filename  ║
# ║ MUST include a dist/z_archive/<file> candidate in its probe      ║
# ║ chain. The legacy runners.json was migrated to                   ║
# ║ 1_configs/build.json + dist/build-workflows.json (2026-05-09)  ║
# ║ and is no longer relevant to this fallback probe.                ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_cloud_data_zarchive_probe.sh
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/1_configs/src/deploy/scripts"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

# Files that derive emits to dist/z_archive/. The legacy runners.json
# was migrated to 1_configs/build.json + dist/build-workflows.json on
# 2026-05-09 and is no longer scanned here.
DEPRECATED_FILES="cloud-data-topology cloud-data-gha-config cloud-data-dns-services cloud-data-configs cloud-data-deps cloud-data-cloudflare-dns cloud-data-monitoring-targets cloud-data-backup-targets cloud-data-container-resources cloud-data-matomo-sites cloud-data-ntfy-acl cloud-data-firewall-rules cloud-data-log-routing cloud-data-databases cloud-data-secrets-env-var-names cloud-data-disk-protection cloud-data-authelia-acl cloud-data-caddy-routes cloud-data-kg-schema cloud-data-repo-scan cloud-data-reports-logs cloud-data-sec-scan cloud-data-url-health"

echo "── Every consumer of a deprecated cloud-data-*.json must probe dist/z_archive/ ──"

for shfile in $(find "$SCRIPTS" -maxdepth 1 -name '*.sh' -type f 2>/dev/null); do
    rel="${shfile#$REPO_ROOT/}"
    for stem in $DEPRECATED_FILES; do
        # Does this script reference the deprecated file?
        if ! grep -q "$stem\.json" "$shfile" 2>/dev/null; then
            continue
        fi
        # If yes, does it also have a dist/z_archive/ probe candidate?
        if grep -qE "z_archive/$stem\.json|dist/z_archive/$stem\.json" "$shfile" 2>/dev/null; then
            pass "$rel: probes z_archive/$stem.json"
        else
            fail "$rel: references $stem.json but missing dist/z_archive/ probe candidate"
        fi
    done
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 40 cloud-data-zarchive-probe: PASS"
    exit 0
else
    echo "Phase 40 cloud-data-zarchive-probe: FAIL"
    exit 1
fi
