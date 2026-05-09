#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ test-bind-host-policy.sh — Tier-3 WG-only bind audit             ║
# ║                                                                  ║
# ║ Iterates every a_solutions/*/build.json and cross-references     ║
# ║ declared bind_host (top-level + per-container) against the       ║
# ║ allowlist + grandfather list in 2_configs/build.json#policy.     ║
# ║                                                                  ║
# ║ Fails on any unauthorised bind_host=0.0.0.0. Grandfathered       ║
# ║ entries WARN (loud, but non-fatal) until slot 3 lands the        ║
# ║ migration; remove them from grandfathered_violations afterwards. ║
# ║                                                                  ║
# ║ Wired via 2_configs/build.sh test, plus runtime-mirrored by      ║
# ║ 1_workflows/src/test/test_bind_host_policy.sh which scans the    ║
# ║ rendered docker-compose.yml output (catches escape via ports:    ║
# ║ stanzas added directly inside flake.nix).                        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POLICY_FILE="$CLOUD_ROOT/2_configs/build.json"
SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"

if ! command -v jq >/dev/null 2>&1; then
  echo "[bind-host-policy] jq missing — skipping (install jq to enable enforcement)"
  exit 0
fi

if [ ! -f "$POLICY_FILE" ]; then
  echo "[bind-host-policy] FAIL: policy file missing at $POLICY_FILE"
  exit 1
fi

# Build allowlist + grandfather sets keyed by service::container.
allowlist=$(jq -r '.policy.public_bindings_allowlist // [] | .[] | "\(.service)::\(.container)"' "$POLICY_FILE" | sort -u)
grandfather=$(jq -r '.policy.grandfathered_violations // [] | .[] | "\(.service)::\(.container)"' "$POLICY_FILE" | sort -u)

fail=0
warn=0

while IFS= read -r bj; do
  [ -f "$bj" ] || continue
  folder=$(basename "$(dirname "$bj")")
  case "$folder" in z_archive*|_*) continue ;; esac

  svc=$(jq -r '.name // ""' "$bj")
  [ -z "$svc" ] && continue

  # Service-wide bind_host (applies to every container without an override).
  svc_bind=$(jq -r '.bind_host // empty' "$bj")

  # Iterate container-name → container-bind pairs.
  while IFS=$'\t' read -r role cname cbind cport; do
    [ -n "$cname" ] || continue
    bind="$cbind"
    [ -z "$bind" ] || [ "$bind" = "null" ] && bind="$svc_bind"
    [ -z "$bind" ] && continue  # unset → engine defaults to vm.wg_ip, OK

    # Only 0.0.0.0 needs allowlist clearance.
    case "$bind" in
      "0.0.0.0")
        key="${svc}::${cname}"
        if echo "$allowlist" | grep -Fxq "$key"; then
          continue
        fi
        if echo "$grandfather" | grep -Fxq "$key"; then
          echo "[bind-host-policy] WARN grandfathered: $key port=${cport:-*} binds 0.0.0.0 (clear via 2_configs/build.json once migrated)"
          warn=$((warn + 1))
          continue
        fi
        echo "[bind-host-policy] FAIL $key (folder=$folder, port=${cport:-*}) declares bind_host=0.0.0.0 but is not allow-listed"
        fail=$((fail + 1))
        ;;
    esac
  done < <(jq -r '
    (.containers // {}) | to_entries[] |
      [ .key, (.value.container_name // .key), (.value.bind_host // ""), (.value.port // "") ] |
      @tsv
  ' "$bj")
done < <(find "$SOLUTIONS_DIR" -maxdepth 2 -name build.json -not -path "*/z_archive/*" -not -path "*/_*/*")

echo "[bind-host-policy] summary: fail=$fail warn=$warn"
[ "$fail" -eq 0 ]
