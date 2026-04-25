#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/test/test_native_build_app_dir.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 18 tester — native_build app_dir resolves to a buildable   ║
# ║ directory containing the manifest the build cmd expects          ║
# ║                                                                  ║
# ║ For each service with docker.native_build.type == "app":         ║
# ║   build cwd = src/ + (native_build.app_dir or ".")               ║
# ║                                                                  ║
# ║ The cmd hints which manifest to expect:                          ║
# ║   "npm ci"  / "npm install"     → package.json + package-lock    ║
# ║   "uv sync" / "uv pip install"  → pyproject.toml                 ║
# ║   "cargo build"                  → Cargo.toml                    ║
# ║                                                                  ║
# ║ If the cwd doesn't contain the expected manifest, the build      ║
# ║ fails CI with a cryptic error. This tester catches it pre-build. ║
# ║                                                                  ║
# ║ Data-driven (FIRE RULE 3): walks every build.json automatically. ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 1_workflows/src/test/test_native_build_app_dir.sh         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
warn() { printf "  ! %s\n" "$1" >&2; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── For type=app services, native_build.app_dir resolves to a directory with the right manifest ──"

CHECKED=0
while IFS= read -r build_json; do
    nb_type=$(jq -r '.docker.native_build.type // empty' "$build_json" 2>/dev/null)
    [ "$nb_type" != "app" ] && continue

    nb_cmd=$(jq -r '.docker.native_build.cmd // empty' "$build_json" 2>/dev/null)
    nb_dir=$(jq -r '.docker.native_build.app_dir // "."' "$build_json" 2>/dev/null)
    svc_dir=$(dirname "$build_json")
    src_dir="$svc_dir/src"
    cwd="$src_dir"
    [ "$nb_dir" != "." ] && cwd="$src_dir/$nb_dir"
    rel_svc=$(basename "$svc_dir")

    if [ ! -d "$cwd" ]; then
        fail "$rel_svc: native_build.app_dir='$nb_dir' resolves to '$cwd' which doesn't exist"
        continue
    fi

    # Pick the expected manifest by inspecting the cmd
    case "$nb_cmd" in
        *"npm ci"*|*"npm install"*)
            if [ ! -f "$cwd/package.json" ]; then
                fail "$rel_svc: cmd='$nb_cmd' but no package.json in $cwd"
                continue
            fi
            if echo "$nb_cmd" | grep -q "npm ci" && [ ! -f "$cwd/package-lock.json" ] && [ ! -f "$cwd/npm-shrinkwrap.json" ]; then
                fail "$rel_svc: 'npm ci' requires package-lock.json in $cwd"
                continue
            fi
            pass "$rel_svc: npm cwd=$cwd ✓"
            ;;
        *"uv sync"*|*"uv pip"*)
            if [ ! -f "$cwd/pyproject.toml" ]; then
                fail "$rel_svc: cmd='$nb_cmd' but no pyproject.toml in $cwd"
                continue
            fi
            pass "$rel_svc: uv cwd=$cwd ✓"
            ;;
        *"cargo build"*|*"cargo install"*)
            if [ ! -f "$cwd/Cargo.toml" ]; then
                fail "$rel_svc: cmd='$nb_cmd' but no Cargo.toml in $cwd"
                continue
            fi
            pass "$rel_svc: cargo cwd=$cwd ✓"
            ;;
        "")
            warn "$rel_svc: native_build.type=app but no cmd"
            ;;
        *)
            pass "$rel_svc: cwd=$cwd (cmd '$nb_cmd' not introspected)"
            ;;
    esac
    CHECKED=$((CHECKED + 1))
done < <(find "$REPO_ROOT/a_solutions" -maxdepth 2 -name build.json -not -path "*/z_archive/*" 2>/dev/null)

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "Phase 18 native_build app_dir: PASS ($CHECKED type=app services)"
    exit 0
else
    echo ""
    echo "Phase 18 native_build app_dir: FAIL"
    exit 1
fi
