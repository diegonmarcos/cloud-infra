#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Shared library: canonical path resolution                        ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   . "$LIB_DIR/cloud-paths.sh"                                    ║
# ║   GHA_CFG=$(cloud_paths_gha_config) || exit 1                   ║
# ║   CONS=$(cloud_paths_consolidated)                              ║
# ║                                                                  ║
# ║ Why: today's 14-iteration outage had 3+ scripts each with their  ║
# ║ own fallback chain for cloud-data-gha-config.json /              ║
# ║ _cloud-data-consolidated.json. When one was renamed              ║
# ║ (cloud-data-gha-config.json → build-gha.json), some scripts      ║
# ║ caught up and others didn't (ship-services.sh in unix still has  ║
# ║ the old path). One library = one place to update on rename.      ║
# ║                                                                  ║
# ║ Each function prints the resolved absolute path on stdout, or    ║
# ║ returns 1 with a diagnostic on stderr if no candidate exists.    ║
# ║                                                                  ║
# ║ CLOUD_ROOT can be set by the caller; otherwise inferred.         ║
# ╚══════════════════════════════════════════════════════════════════╝

# Guard against double-sourcing.
[ "${_CLOUD_PATHS_LOADED:-}" = "1" ] && return 0
_CLOUD_PATHS_LOADED=1

# Resolve CLOUD_ROOT lazily — caller may not have set it.
_cloud_paths_root() {
    if [ -n "${CLOUD_ROOT:-}" ] && [ -d "$CLOUD_ROOT" ]; then
        printf '%s' "$CLOUD_ROOT"
        return 0
    fi
    # Walk up from this lib's location until we find a config.json.
    _cpr_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    while [ "$_cpr_dir" != "/" ]; do
        if [ -f "$_cpr_dir/config.json" ] && [ -d "$_cpr_dir/a_solutions" ]; then
            printf '%s' "$_cpr_dir"
            return 0
        fi
        _cpr_dir="$(dirname "$_cpr_dir")"
    done
    return 1
}

# Internal: walk a fallback list and print the first existing path.
# Args: $1 = friendly-name (for error message), $2..$N = candidate paths.
_cloud_paths_first_existing() {
    _cpfe_name="$1"; shift
    for _cpfe_p in "$@"; do
        [ -f "$_cpfe_p" ] && { printf '%s' "$_cpfe_p"; return 0; }
    done
    printf 'cloud-paths: %s not found in any of: %s\n' "$_cpfe_name" "$*" >&2
    return 1
}

# Public: _cloud-data-consolidated.json — the ONE source of truth that
# the per-concern dist files derive from.
cloud_paths_consolidated() {
    _cpc_root="$(_cloud_paths_root)" || return 1
    _cloud_paths_first_existing "_cloud-data-consolidated.json" \
        "/app/_cloud-data-consolidated.json" \
        "$_cpc_root/1_cloud-configs/dist/_cloud-data-consolidated.json" \
        "$_cpc_root/cloud-data/_cloud-data-consolidated.json" \
        "$_cpc_root/_cloud-data-consolidated.json"
}

# Public: GHA-shape config (vms/services with ssh_secret + ssh_alias join).
# Prefers per-service-naming build-gha.json, falls back to legacy
# cloud-data-gha-config.json, then derives from consolidated.
# Returns ABSOLUTE path; if derived, materialised at $RUNNER_TEMP/gha-config.json.
cloud_paths_gha_config() {
    _cpgc_root="$(_cloud_paths_root)" || return 1
    # Prefer canonical build-gha.json (post-2026-04-27 migration).
    for _p in \
        "/app/build-gha.json" \
        "$_cpgc_root/1_cloud-configs/dist/build-gha.json" \
        "$_cpgc_root/cloud-data/build-gha.json" \
        "$_cpgc_root/build-gha.json"; do
        [ -f "$_p" ] && { printf '%s' "$_p"; return 0; }
    done
    # Fallback: derive _gha slice from consolidated, joining wg_ip from vms.
    _cpgc_cons="$(cloud_paths_consolidated 2>/dev/null)" || true
    if [ -n "$_cpgc_cons" ]; then
        _cpgc_out="${RUNNER_TEMP:-/tmp}/gha-config.json"
        jq '
          ._gha as $g
          | (.vms | to_entries | map({key: .value.ssh_alias, value: .value.wg_ip}) | from_entries) as $alias_to_wg
          | $g
          | .vms |= with_entries(.value += {wg_ip: ($alias_to_wg[.key] // null)})
        ' "$_cpgc_cons" > "$_cpgc_out" 2>/dev/null && { printf '%s' "$_cpgc_out"; return 0; }
    fi
    # Last-resort legacy path.
    _cloud_paths_first_existing "build-gha.json (or legacy cloud-data-gha-config.json)" \
        "/app/cloud-data-gha-config.json" \
        "$_cpgc_root/1_configs/dist/cloud-data-gha-config.json" \
        "$_cpgc_root/cloud-data/cloud-data-gha-config.json" \
        "$_cpgc_root/cloud-data-gha-config.json"
}

# Public: build-workflows.json — arch → runner mapping (amd64=local,
# arm64=local). Both arches build natively on the arch-matching GHA hosted
# runner (amd64→ubuntu-latest, arm64→ubuntu-24.04-arm), selected per-VM in
# .github/workflows/ship.yml from .vms[].specs.arch. Migrated 2026-08-07 off
# the arm64=ssh oci-apps cloud-builder-x path (cold cacheless arm64 builds
# exceeded the ship clock). Migrated 2026-05-09 from the legacy runners.json
# that lived under I_cloud-data/ (now z_archive). Source-of-truth is now
# 1_configs/build.json (.runners + .probe + .dispatch), aggregated by
# 1_configs/build.sh into dist/build-workflows.json. Schema unchanged:
# .runners[$arch].{type,host?,builder_image?}; the ssh runner-type is still
# supported for any future remote-builder arch (currently unused).
cloud_paths_runners() {
    _cpr_root="$(_cloud_paths_root)" || return 1
    _cloud_paths_first_existing "build-workflows.json" \
        "/app/build-workflows.json" \
        "$_cpr_root/1_cloud-configs/dist/build-workflows.json" \
        "$_cpr_root/1_configs/src/build-workflows.json"
}

# Public: $CLOUD_ROOT (resolved).
cloud_paths_root() {
    _cloud_paths_root
}
