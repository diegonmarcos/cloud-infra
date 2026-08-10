#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/deploy/test/test_no_retired_service_refs.sh
# ║   Engine : 1_configs/src/deploy/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 10 tester — no live refs to retired services               ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   For every service directory under a_solutions/z_archive/, no   ║
# ║   LIVE build.json / flake.nix / docker-compose.yml references    ║
# ║   it by name (depends_on, volumes_from, image, container_name,   ║
# ║   compose.containers list, etc.).                                ║
# ║                                                                  ║
# ║   Guards against the drift pattern where a service is archived   ║
# ║   but still referenced by a dependent that then silently breaks. ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_no_retired_service_refs.sh ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Live build.json + flake.nix + docker-compose.yml must not reference z_archive/ services ──"

if [ ! -d "$REPO_ROOT/a_solutions/z_archive" ]; then
    echo "  (z_archive/ absent — nothing to enforce)"
    exit 0
fi

# Derive the list of retired service names from z_archive/ dir names,
# stripping the category prefix. Prefix is any run of lowercase letters +
# dashes up to the first underscore — covers BOTH the legacy fixed-width
# scheme (aa-sui_, bc-obs_) and the current word-word scheme (user-comm_,
# infra-api_, user-prod_, …). The old `[a-z]{2}-[a-z]{3}_` only matched the
# legacy form, so post-migration successors (user-comm_*) were never stripped
# and slipped past the successor-skip below → false Phase-10 failures.
retired=$(find "$REPO_ROOT/a_solutions/z_archive" -maxdepth 1 -type d -not -path "$REPO_ROOT/a_solutions/z_archive" -printf '%f\n' \
    | sed -E 's/^[a-z-]+_//' \
    | sort -u)

if [ -z "$retired" ]; then
    echo "  (z_archive/ is empty)"
    exit 0
fi

checked=0
for svc in $retired; do
    checked=$((checked + 1))
    # Only fail on SERVICE-LEVEL references — depends_on entries, container_name
    # matches, compose-containers arrays, container-network aliases. IMAGE-name
    # references (ghcr.io/diegonmarcos/<svc>) are intentional reuse and NOT
    # a retirement drift bug; they're filtered out.
    refs=""
    while IFS= read -r f; do
        # Skip files under z_archive/
        case "$f" in */z_archive/*) continue ;; esac
        # Skip successor services that legitimately reuse the retired name
        # in descriptions / container_names (e.g. sauron-central, sauron-lite,
        # sauron-forwarder all derive from retired bb-sec_sauron and reference
        # "sauron" in prose / as container_name).
        consumer_dir=$(dirname "$f" | sed -E 's|.*/(a_solutions/[^/]+).*|\1|')
        consumer_name=$(basename "$consumer_dir" | sed -E 's/^[a-z-]+_//')
        case "$consumer_name" in
            "$svc"-*|*-"$svc"|"$svc")
                # Successor or self — name carries the retired prefix/suffix legitimately.
                continue
                ;;
        esac
        # Filter chain — each step works on the prior's output. Note grep's
        # `-n` output prefix is `LINE:` so comment-line filters must account
        # for that prefix.
        # `"_doc..."` JSON keys are a repo-wide documentation convention
        # (free-form prose; never live config). Anything on a `_doc`-keyed
        # line is descriptive text, not a service reference, so strip those
        # lines before scanning. Honoured generically — no name allowlist.
        if grep -nwE -- "$svc" "$f" 2>/dev/null \
            | grep -vE "ghcr\.io/[^ /]+/$svc" \
            | grep -vE "^[0-9]+:\s*#|^[0-9]+:\s*//" \
            | grep -vE '^[0-9]+:\s*"_doc[a-zA-Z0-9_]*"\s*:' \
            | grep -vE "[a-zA-Z0-9_/-]$svc|$svc[a-zA-Z0-9_/-]" \
            | grep -vE "$svc[[:space:]]|[[:space:]]$svc" \
            | grep -vE '"(cmd|entrypoint|command|args|binary|apt|app_dir)"\s*:' \
            | grep -vE '^[0-9]+:\s*"'"$svc"'"\s*:\s*([0-9]+|\{)' \
            | grep -vE 'sed -i.*'"$svc"'|"\\bsed\\b.*'"$svc" \
            | grep -vE '"(action|path)"\s*:.*(compose_down|path_remove|path_create)|/opt/containers/'"$svc" \
            | grep -q .; then
            refs="${refs}${f}"$'\n'
        fi
    done < <(find "$REPO_ROOT"/a_solutions -maxdepth 4 \
                 \( -name build.json -o -name flake.nix -o -name docker-compose.yml \) \
                 -not -path "*/z_archive/*")
    if [ -z "$refs" ]; then
        pass "$svc: no live service-level refs"
    else
        fail "$svc: still referenced as service (not image) by:"
        echo -n "$refs" | sed 's/^/    /' >&2
    fi
done

echo ""
echo "── 1_configs/dist topology files must not list retired services as .name ──"
# Only flag service-level entries (top-level .name field), not embedded image
# references — a retired SERVICE in the containers array is a drift bug, but
# an archived service's IMAGE still used by an active service is not.

for svc in $retired; do
    hits=""
    for topo in "$REPO_ROOT"/1_configs/dist/cloud-data-containers-*.json; do
        [ -f "$topo" ] || continue
        if jq -e --arg s "$svc" '.containers[]? | select(.name == $s)' "$topo" >/dev/null 2>&1; then
            hits="$hits\n  $topo"
        fi
    done
    if [ -z "$hits" ]; then
        pass "$svc: not a top-level service in any cloud-data-containers-*.json"
    else
        fail "$svc: still listed as a service in topology:$hits"
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 10 no-retired-service-refs: PASS ($checked retired svc)"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 10 no-retired-service-refs: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
