#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_configs/src/gha/scripts/cloud-ship-container-step-verify-secret-consumption.sh
# ║   Engine : 1_configs/src/gha/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_configs/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ════════════════════════════════════════════════════════════════════════
# cloud-ship-container-step-verify-secret-consumption.sh
#
# Build-time gate that scans every cloud service for forbidden patterns
# in secret consumption. The decrypted material is already available
# inside every container as $KEY (env_file), /run/secrets/<KEY> (file),
# or /run/secrets.json (JSON) — anything else is a regression.
#
# Sourced by cloud-ship-container-engine.sh (per-service mode) and
# also runnable standalone with no args (repo-wide mode, used by CI).
#
# Modes:
#   warn (default)  print offenders to stderr, exit 0
#   fail            print offenders, exit 1 if any found
#
# Per-line allowlist: any line containing the literal token
#   GATE_ALLOW: <reason>
# is skipped. Reason is printed in the report so reviewers see why.
#
# Service-level allowlist: bd-cloud-builder-x is the dev/CI builder
# itself and legitimately mounts host SSH/sops; skipped entirely.
#
# Sources of truth scanned:
#   src/templates/*.{sh,sh.tpl,tpl}
#   src/code/**/*.{sh,py,js,ts}
#   src/dags/*.yaml                 (Dagu DAG files)
#   src/compose.nix                 (compose volume mounts)
#   dist/configs/**                 (post-template-substitution forms)
#   dist/compose/docker-compose.yml dist/docker-compose.yml
# ════════════════════════════════════════════════════════════════════════
set -uo pipefail

# Service-level allowlist. The dev/CI builder itself needs host mounts.
SERVICE_ALLOWLIST_REGEX='^bd-cloud-builder-x$'

# Path-level skip. These directories are NOT container init/runtime —
# they're bundled third-party scripts or legacy local-dev tooling that
# users invoke from their own machine. Out of scope for the gate.
PATH_SKIP_REGEX='/(node_modules|\.cargo-home|target|\.git)/|/dist/assets/repo/|/src/analytics-app/|/src/code/manage/'

# ── Forbidden patterns ──────────────────────────────────────────────
# Each line below is one pattern. Format: TAG|PCRE
# TAG is a short label printed in the report (helps reviewers triage).
# Patterns must NOT match comments (the line-filter step strips those
# before grep) — write tight regexes, not loose ones.
PATTERNS=(
'sed-secret|sed[[:space:]]+-i\b[^#]*\$[A-Z_]*(SECRET|PASSWORD|TOKEN|KEY|PASS|HASH|HMAC)\b'
'envsubst|\benvsubst\b'
'argv-pass|(--password|--token|--secret|--api-key)[[:space:]]+["'"'"']?\$'
'eval-secret|\beval[[:space:]]+["'"'"']?val=\\\$\$'
'json-shell|-d[[:space:]]+["'"'"']\{[^}]*\$\{?[A-Z_]*(SECRET|PASSWORD|TOKEN|HASH)'
'default-secret|\$\{[A-Z_]*(SECRET|PASSWORD|TOKEN|HASH|PASS|KEY)[A-Z_]*:\-[^}]+\}'
'host-ssh|/opt/ssh-keys/|[~$]\{?HOME[^}]*\}?/\.ssh|/root/\.ssh:|/home/[^/]+/\.ssh:'
'host-sops|[~$]\{?HOME[^}]*\}?/\.config/sops|/\.gnupg'
)

# Strip comment lines (shell # / yaml #) before pattern-matching.
# Awk filter that also keeps line numbers for reporting.
strip_comments() {
    awk 'BEGIN{ ln=0 } { ln++; if ($0 !~ /^[[:space:]]*#/) print ln":"$0 }' "$1"
}

# Helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; CYA='\033[0;36m'; RST='\033[0m'

# In CI / non-tty, drop colour
[ -t 2 ] || { RED=''; YEL=''; CYA=''; RST=''; }

OFFENDERS=()

scan_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    [ -r "$f" ] || return 0
    # Path-level skip (third-party bundled, legacy local-dev, vendor)
    if echo "$f" | grep -Eq "$PATH_SKIP_REGEX"; then
        return 0
    fi
    # Service-level skip
    local svc_dir
    svc_dir=$(echo "$f" | awk -F'/a_solutions/' '{print $2}' | awk -F/ '{print $1}')
    if [ -n "$svc_dir" ] && echo "$svc_dir" | grep -Eq "$SERVICE_ALLOWLIST_REGEX"; then
        return 0
    fi
    # Read non-comment lines once, with original line numbers preserved
    local stripped
    stripped=$(strip_comments "$f")
    [ -z "$stripped" ] && return 0
    local pat tag rx
    for pat in "${PATTERNS[@]}"; do
        tag="${pat%%|*}"
        rx="${pat#*|}"
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            # Per-line allowlist: skip lines with GATE_ALLOW: <reason>
            if echo "$hit" | grep -q 'GATE_ALLOW:'; then
                continue
            fi
            OFFENDERS+=("[$tag] $f:$hit")
        done < <(printf '%s\n' "$stripped" | grep -P "$rx" 2>/dev/null || true)
    done
}

scan_service() {
    local svc_root="$1"
    local svc_name
    svc_name=$(basename "$svc_root")
    if echo "$svc_name" | grep -Eq "$SERVICE_ALLOWLIST_REGEX"; then
        return 0
    fi

    # src/ side
    while IFS= read -r f; do scan_file "$f"; done < <(
        find "$svc_root/src" \
            \( -path '*/node_modules' -o -path '*/.cargo-home' -o -path '*/target' \) -prune -o \
            -type f \( \
                -name '*.sh' -o -name '*.sh.tpl' -o -name '*.tpl' \
                -o -name '*.py' -o -name '*.js' -o -name '*.ts' \
                -o -name '*.yaml' -o -name '*.yml' \
                -o -name 'compose.nix' \
            \) -print 2>/dev/null
    )

    # dist/ side (post-template-substitution forms)
    while IFS= read -r f; do scan_file "$f"; done < <(
        find "$svc_root/dist" -type f \( \
            -name '*.sh' -o -name '*.tpl' \
            -o -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
        \) -print 2>/dev/null
    )
}

# ── Per-service mode (sourced by container engine) ─────────────────
step_verify_secrets() {
    CURRENT_STEP="verify-secrets"
    OFFENDERS=()
    scan_service "$SERVICE_DIR"
    report_offenders "$SERVICE_NAME" "${VERIFY_SECRETS_MODE:-warn}"
}

# ── Repo-wide mode (CI runs this) ──────────────────────────────────
run_repo_wide() {
    local cloud_root mode
    cloud_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
    mode="${VERIFY_SECRETS_MODE:-warn}"
    OFFENDERS=()
    while IFS= read -r svc_root; do
        [ -d "$svc_root" ] || continue
        scan_service "$svc_root"
    done < <(find "$cloud_root/a_solutions" -mindepth 1 -maxdepth 1 -type d \
                -not -name '_shared' -not -name 'z_archive' -not -name '.*' 2>/dev/null | sort)
    report_offenders "<repo>" "$mode"
}

report_offenders() {
    local label="$1" mode="$2"
    local count=${#OFFENDERS[@]}
    if [ "$count" -eq 0 ]; then
        printf '%b[verify-secrets]%b %s: 0 offenders\n' "$CYA" "$RST" "$label" >&2
        return 0
    fi
    {
        printf '%b[verify-secrets]%b %s: %d offender(s) — %s mode\n' \
            "$YEL" "$RST" "$label" "$count" "$mode"
        printf '%b%s%b\n' "$RED" "$(printf '%s\n' "${OFFENDERS[@]}")" "$RST"
        printf '%b[verify-secrets]%b Forbidden tags reference (in ~/.claude/plans/nifty-doodling-reddy.md):\n' \
            "$CYA" "$RST"
        printf '  sed-secret    sed -i with secret env var → corrupts on & or \\\n'
        printf '  envsubst      envsubst on secret material → use daemon-native env interp\n'
        printf '  argv-pass     secret on CLI argv → visible to ps/docker top\n'
        printf '  eval-secret   eval reading secret env var → eliminate, use file mount\n'
        printf '  json-shell    JSON body via shell interp → use jq -nc | curl -d @-\n'
        printf '  default-secret  fallback default for password env → use ${VAR:?} fail-fast\n'
        printf '  host-ssh      host-side SSH bind mount → put key in secrets.yaml\n'
        printf '  host-sops     host-side sops/gpg bind mount → engine handles decryption\n'
        printf '%bAdd "GATE_ALLOW: <reason>" to a line to allowlist with documented exception.%b\n' \
            "$CYA" "$RST"
    } >&2
    if [ "$mode" = "fail" ]; then
        return 1
    fi
    return 0
}

# ── Standalone invocation: repo-wide scan ──────────────────────────
# When sourced (BASH_SOURCE[0] != $0), we just expose step_verify_secrets.
# When executed directly, run repo-wide.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-}" in
        --fail) shift; export VERIFY_SECRETS_MODE=fail ;;
        --warn) shift; export VERIFY_SECRETS_MODE=warn ;;
    esac
    run_repo_wide "${1:-}"
fi
