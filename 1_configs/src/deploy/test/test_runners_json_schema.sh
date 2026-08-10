#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 37 tester — build-workflows.json schema invariants      ║
# ║                                                                  ║
# ║ Audit P2 #7 (2026-05-05): runners.json had no formal schema, so  ║
# ║ silent breakage was possible if a key got renamed/dropped. This  ║
# ║ test asserts the minimal contract every consumer relies on.      ║
# ║                                                                  ║
# ║ Required keys:                                                   ║
# ║   _comment            — human-readable purpose                   ║
# ║   _source             — origin file path (for git-blame trail)   ║
# ║   runners             — arch → execution-mode object             ║
# ║                                                                  ║
# ║ Per-runner contract:                                             ║
# ║   .type               — required: "local" | "ssh"                ║
# ║   .host               — required when .type == "ssh"             ║
# ║                                                                  ║
# ║ Image identity is NOT in this file — it lives in                 ║
# ║   II_Unix/cb_containers-builders/build.json                     ║
# ║ (the producer's master). Legacy .runners[$a].builder_image is    ║
# ║ accepted for back-compat but not required.                       ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_runners_json_schema.sh     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

# Locate build-workflows.json (same probe order as engine scripts).
RUNNERS_JSON=""
for p in \
    "/app/build-workflows.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/dist/build-workflows.json" \
    "${CLOUD_ROOT:-$REPO_ROOT}/1_configs/src/build-workflows.json"; do
    [ -f "$p" ] && { RUNNERS_JSON="$p"; break; }
done

if [ -z "$RUNNERS_JSON" ]; then
    fail "build-workflows.json not found in any expected location"
    echo "Phase 37 runners-schema: FAIL"
    exit 1
fi
echo "── Schema invariants for $RUNNERS_JSON ──"

# Required top-level keys.
for key in _comment _source runners; do
    if jq -e --arg k "$key" 'has($k)' "$RUNNERS_JSON" >/dev/null 2>&1; then
        pass "top-level '$key' present"
    else
        fail "top-level '$key' missing"
    fi
done

# Each runner has a type; ssh runners have a host.
while IFS=$'\t' read -r arch type host; do
    [ -z "$arch" ] && continue
    if [ -z "$type" ] || [ "$type" = "null" ]; then
        fail "runners.$arch.type missing or null"
        continue
    fi
    case "$type" in
        local)
            pass "runners.$arch.type='local' (no host required)"
            ;;
        ssh)
            if [ -z "$host" ] || [ "$host" = "null" ]; then
                fail "runners.$arch.type='ssh' but .host missing"
            else
                pass "runners.$arch.type='ssh' host='$host'"
            fi
            ;;
        *)
            fail "runners.$arch.type='$type' — must be 'local' or 'ssh'"
            ;;
    esac
done < <(jq -r '.runners | to_entries[] | "\(.key)\t\(.value.type // "")\t\(.value.host // "")"' "$RUNNERS_JSON")

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Phase 37 runners-schema: PASS"
    exit 0
else
    echo "Phase 37 runners-schema: FAIL"
    exit 1
fi
