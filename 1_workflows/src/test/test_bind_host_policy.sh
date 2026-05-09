#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ test_bind_host_policy.sh — Tier-3 WG-only bind audit (CI mirror) ║
# ║                                                                  ║
# ║ Twin of 2_configs/src/engines/test-bind-host-policy.sh.          ║
# ║                                                                  ║
# ║ The deriver test catches violations in build.json declarations.  ║
# ║ THIS test catches violations in the *rendered* artefacts:         ║
# ║   - a_solutions/*/dist/compose/docker-compose.yml                ║
# ║   - a_solutions/*/dist/build-{name}.json                         ║
# ║                                                                  ║
# ║ Together they form a belt-and-braces guard:                       ║
# ║   - the deriver guard fails BEFORE dist/ is written;              ║
# ║   - this CI guard fails AFTER dist/ is written, catching any      ║
# ║     escape via per-flake ports: stanzas, environment-injected    ║
# ║     listen addresses, or hand-edited dist/ artefacts.             ║
# ║                                                                  ║
# ║ Allowlist source of truth: 2_configs/build.json#policy.           ║
# ║                                                                  ║
# ║ Wired into .github/workflows/lint-pipeline.yml.                   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POLICY_FILE="$CLOUD_ROOT/2_configs/build.json"
SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"

if ! command -v jq >/dev/null 2>&1; then
  echo "[test_bind_host_policy] jq missing — skipping"
  exit 0
fi

if [ ! -f "$POLICY_FILE" ]; then
  echo "[test_bind_host_policy] FAIL: policy file missing at $POLICY_FILE"
  exit 1
fi

allowlist=$(jq -r '.policy.public_bindings_allowlist // [] | .[] | "\(.service)::\(.container)"' "$POLICY_FILE" | sort -u)
grandfather=$(jq -r '.policy.grandfathered_violations // [] | .[] | "\(.service)::\(.container)"' "$POLICY_FILE" | sort -u)

fail=0
warn=0
checked=0

# ── Pass A: scan rendered docker-compose.yml ports stanzas ─────────────
# Compose YAML is JSON-emitted by the engine (lib.generators.toYAML); jq parses it.
while IFS= read -r yml; do
  [ -f "$yml" ] || continue
  folder=$(echo "$yml" | awk -F'/' '{ for (i=1;i<=NF;i++) if ($i=="a_solutions") { print $(i+1); break } }')
  case "$folder" in z_archive*|_*) continue ;; esac
  checked=$((checked + 1))

  while IFS=$'\t' read -r role port_entry; do
    [ -n "$role" ] && [ -n "$port_entry" ] || continue
    case "$port_entry" in
      "0.0.0.0:"*)
        cname=$(jq -r --arg r "$role" '.services[$r].container_name // $r' "$yml")
        # service folder name → strip prefix (aa-sui_, bb-sec_, ...)
        svc="${folder#*_}"
        key="${svc}::${cname}"
        port="${port_entry#0.0.0.0:}"
        port="${port%%:*}"
        if echo "$allowlist" | grep -Fxq "$key"; then
          continue
        fi
        if echo "$grandfather" | grep -Fxq "$key"; then
          echo "[test_bind_host_policy] WARN grandfathered: $key port=$port (compose: $yml)"
          warn=$((warn + 1))
          continue
        fi
        echo "[test_bind_host_policy] FAIL $key port=$port — bare 0.0.0.0 binding in $yml not in allowlist"
        fail=$((fail + 1))
        ;;
    esac
  done < <(jq -r '
    .services // {} | to_entries[] |
    select(.value.ports) |
    .key as $r | .value.ports[] | [ $r, (.|tostring) ] | @tsv
  ' "$yml" 2>/dev/null || true)
done < <(find "$SOLUTIONS_DIR" -path "*/dist/compose/docker-compose.yml" -not -path "*/z_archive/*")

# ── Pass B: scan derived build-{name}.json bind_host fields ─────────────
DIST_DIR="$CLOUD_ROOT/2_configs/dist"
if [ -d "$DIST_DIR" ]; then
  while IFS= read -r bjp; do
    [ -f "$bjp" ] || continue
    bind=$(jq -r '.bind_host // empty' "$bjp" 2>/dev/null || true)
    [ "$bind" = "0.0.0.0" ] || continue
    svc=$(jq -r '.service // empty' "$bjp")
    cname=$(jq -r '.container.container_name // empty' "$bjp")
    [ -n "$svc" ] && [ -n "$cname" ] || continue
    key="${svc}::${cname}"
    port=$(jq -r '.container.port // ""' "$bjp")
    if echo "$allowlist" | grep -Fxq "$key"; then
      continue
    fi
    if echo "$grandfather" | grep -Fxq "$key"; then
      echo "[test_bind_host_policy] WARN grandfathered: $key port=${port:-*} (build: $bjp)"
      warn=$((warn + 1))
      continue
    fi
    echo "[test_bind_host_policy] FAIL $key port=${port:-*} — derived bind_host=0.0.0.0 in $bjp not in allowlist"
    fail=$((fail + 1))
  done < <(find "$DIST_DIR" -maxdepth 1 -name 'build-*.json' -not -name 'build-vm-*.json' -not -name 'build-gha.json' -not -name 'build-reports.json' -not -name 'build-kg-*.json' -not -name 'build-workflows.json')
fi

echo "[test_bind_host_policy] summary: checked=$checked compose files, fail=$fail, warn=$warn"
[ "$fail" -eq 0 ]
