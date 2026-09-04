#!/usr/bin/env bash
# ── Full mail health diagnostic + cross-store reconciliation ──
# Usage: cloud-health-mail-full.sh
#
# Two layers, both must pass:
#
#  1. LIVENESS/E2E — triggers the Rust cloud-mail-health-full derive on
#     oci-apps (identical docker invocation to obs.health.mail —
#     a_solutions/infra-api_c3-infra-mcp/src/code/mcp/tools/health_mail.ts —
#     and to the working dagu DAG a_solutions/infra-obs_dagu/src/dags/
#     health_mail-full.yaml). 7-phase path/container/network/DNS/e2e probe.
#     Gate: .summary.critical == 0.
#
#  2. CROSS-STORE RECONCILIATION — the liveness probe above does NOT compare
#     message counts, so a store silently falling behind (e.g. maddy's
#     dual-write to Stalwart failing) goes undetected — this is exactly what
#     caused the 2026-08-11..08-20 silent mail-loss incident. This layer
#     counts messages received in the last 24h on Gmail (authoritative
#     primary), maddy, and Stalwart, and fails if any store's count diverges
#     from Gmail's beyond tolerance. Reuses existing scripts, no new
#     clients/credentials:
#       - a_solutions/infra-api_cloud-mail-mcp/src/code/mcp/tools/others/count-since.ts
#         (maddy IMAP + Stalwart JMAP, run via `docker exec cloud-mail-mcp`)
#       - a_solutions/infra-api_google-workspace-mcp/src/code/gmail/count_recent.py
#         (Gmail REST API via the container's service account, run via
#         `docker exec google-workspace-mcp`)
#     Both containers run on oci-apps (see each service's build.json
#     deploy.host) — reached over the SAME SSH alias the caller (the GHA
#     workflow) already set up for the liveness check.
#
# Requires (set up by the caller — see 1_cicd/src/cicd/health_mail_full.yml):
#   - SSH config alias `oci-apps` (same pattern as
#     1_cicd/src/cicd/cloud-health-reports.yml's "Setup SSH config" step)
#   - jq on PATH (ubuntu-latest ships it)
# Optional (ntfy alert on failure — same topic/headers/tags the working
# dagu DAG health_mail-full.yaml already uses, so the existing ntfy→
# Mattermost bridge — health_ntfy-mattermost-sync.yaml — picks it up):
#   NTFY_URL, AUTHELIA_BEARER_TOKEN, AUTHELIA_TOKEN_URL,
#   AUTHELIA_OIDC_CLIENT_ID, AUTHELIA_OIDC_CLIENT_SECRET
#   (same env var NAMES as a_solutions/infra-obs_dagu/src/secrets.yaml /
#   compose.nix — NOT currently populated as GitHub Actions secrets; if
#   unset, the alert step is skipped with a warning but the check itself
#   still passes/fails and exits non-zero on failure, which GitHub's own
#   default scheduled-workflow-failure email will surface either way).
set -uo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
REPORT_IMAGE="ghcr.io/diegonmarcos/cloud-data-reports:latest"
NTFY_URL="${NTFY_URL:-http://10.0.0.6:8090}"
NTFY_TOPIC="infra_mail-health"
# The ntfy alert is best-effort: it must never hold the job. Without these the
# SSH sat ~10min on a half-open mesh connection before dying on a broken pipe.
# ConnectTimeout caps the handshake; ServerAlive* kills a silently-dropped
# session after ~30s; the `timeout 60` wrapper on each call is the hard bound.
NTFY_SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

# Mint a fresh client_credentials token where possible (same reasoning as
# a_solutions/infra-obs_dagu/src/dags/health_mail-full.yaml: a long-lived
# AUTHELIA_BEARER_TOKEN secret goes stale ~1h after mint, so every alert
# would silently 401 by the time this runs on a schedule). Falls back to a
# static AUTHELIA_BEARER_TOKEN if client-credentials env vars aren't set.
BEARER="${AUTHELIA_BEARER_TOKEN:-}"
if [ -n "${AUTHELIA_TOKEN_URL:-}" ] && [ -n "${AUTHELIA_OIDC_CLIENT_ID:-}" ] && [ -n "${AUTHELIA_OIDC_CLIENT_SECRET:-}" ]; then
  FRESH_TOKEN=$(curl -s --max-time 10 -X POST "$AUTHELIA_TOKEN_URL" \
    -u "$AUTHELIA_OIDC_CLIENT_ID:$AUTHELIA_OIDC_CLIENT_SECRET" \
    -d "grant_type=client_credentials&scope=authelia.bearer.authz" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
  [ -n "$FRESH_TOKEN" ] && BEARER="$FRESH_TOKEN"
fi

# Tolerance for cross-store reconciliation: a store may lag Gmail (the
# authoritative primary) by up to 2 messages OR 5%, whichever is larger —
# generous enough to absorb in-flight delivery races at the 24h window edge
# and API pagination timing, tight enough to catch a stalled dual-write
# within one run (checks run every 6h, well inside a day).
tolerance_ok() {
  local reference="$1" candidate="$2"
  [ "$reference" -lt 0 ] && return 0   # reference itself failed to count — nothing to compare against
  [ "$candidate" -lt 0 ] && return 1   # candidate failed to count — treat as divergence
  local diff=$(( reference > candidate ? reference - candidate : candidate - reference ))
  local pct_allowance=$(( (reference * 5 + 99) / 100 ))  # ceil(5% of reference)
  local allowance=$(( pct_allowance > 2 ? pct_allowance : 2 ))
  [ "$diff" -le "$allowance" ]
}

FAIL_REASONS=()

echo "═══ 1. Liveness / e2e diagnostic (cloud-mail-health-full, oci-apps) ═══"

# HOST MUST BE oci-apps, not oci-analytics. This layer reads the report engine
# out of the cloud-source mirror inside the dagu_dagu_data volume, and there is
# exactly ONE writer that keeps that mirror current: the ensure-cloud-source
# step of a_solutions/infra-obs_dagu/src/dags/sync_secrets.yaml, which runs in
# the dagu container — and dagu is deployed on oci-apps
# (a_solutions/infra-obs_dagu/src/build.json .deploy.host). oci-analytics still
# carries a same-named dagu_dagu_data volume left over from before dagu moved,
# but no container mounts it and nothing syncs it, so its cloud-source is
# frozen at a pre-reorganisation commit where
# a_solutions/infra-obs_reports/src/build.sh does not exist. Pointing this
# layer at oci-apps makes it read the mirror that self-heals hourly.
#
# $BEARER is forwarded into the container below as BEARER_TOKEN. Without it the
# reports entrypoint aborts with "FATAL: BEARER_TOKEN unset and no vault JWT
# found" — deliberately, so auth-gated probes never false-fail — and this whole
# layer reports "no valid cloud_mail_full.json produced".
RESULT_JSON=$(ssh -n oci-apps "
  set -e
  docker run --pull always --rm --network host \
    -v dagu_dagu_data:/var/lib/dagu/data \
    -v /opt/ssh-keys/dagu:/root/.ssh:ro \
    -e CLOUD_DATA_DIR=/var/lib/dagu/data/cloud-source/1_cloud-configs/dist \
    -e REPORTS_DIR=/var/lib/dagu/data/cloud-source/a_solutions/infra-obs_reports/src \
    -e BEARER_TOKEN='$BEARER' \
    '$REPORT_IMAGE' mail >&2
  docker run --rm --entrypoint sh \
    -v dagu_dagu_data:/var/lib/dagu/data \
    '$REPORT_IMAGE' -c 'cat /var/lib/dagu/data/cloud-source/a_solutions/infra-obs_reports/src/dist/cloud_mail_full.json'
") || { echo "::error::liveness report trigger failed (SSH/docker error)"; FAIL_REASONS+=("liveness report did not run"); RESULT_JSON=""; }

CRITICAL=0; FAILED=0; PASSED=0; WARNINGS=0; TOTAL=0
if [ -n "$RESULT_JSON" ] && echo "$RESULT_JSON" | jq -e . >/dev/null 2>&1; then
  CRITICAL=$(echo "$RESULT_JSON" | jq -r '.summary.critical // 0')
  FAILED=$(echo "$RESULT_JSON" | jq -r '.summary.failed // 0')
  PASSED=$(echo "$RESULT_JSON" | jq -r '.summary.passed // 0')
  WARNINGS=$(echo "$RESULT_JSON" | jq -r '.summary.warnings // 0')
  TOTAL=$(echo "$RESULT_JSON" | jq -r '.summary.total_checks // 0')
  echo "PASS=$PASSED · FAIL=$FAILED · CRIT=$CRITICAL · WARN=$WARNINGS · TOTAL=$TOTAL"
  if [ "$CRITICAL" != "0" ]; then
    FAIL_DETAILS=$(echo "$RESULT_JSON" | jq -r '.path_checks[]?, .containers[]?, .network[]?, .dns_auth[]?, .internals[]?, .e2e_delivery[]? | select(.passed == false) | "  \(.severity // "?"): \(.name) — \(.details)"' | head -15)
    echo "::error::$CRITICAL critical liveness finding(s):"
    echo "$FAIL_DETAILS"
    FAIL_REASONS+=("liveness: $CRITICAL critical finding(s) ($FAILED failed / $TOTAL checks)")
  else
    echo "OK: no critical liveness findings"
  fi
else
  echo "::error::no valid cloud_mail_full.json produced"
  FAIL_REASONS+=("liveness report missing/invalid JSON")
fi

echo ""
echo "═══ 2. Cross-store reconciliation (last 24h: Gmail vs maddy vs Stalwart) ═══"

SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)
echo "Window: since $SINCE"

GMAIL_COUNT=-1
# Ship the script to the remote VM over the SSH stdin channel (no local-file
# dependency on the remote side — this local checkout only exists on the
# GHA runner / dev machine invoking this ops script).
GMAIL_SCRIPT="$REPO_ROOT/a_solutions/infra-api_google-workspace-mcp/src/code/gmail/count_recent.py"
if [ -f "$GMAIL_SCRIPT" ]; then
  GMAIL_RAW=$(ssh oci-apps "cat > /tmp/count_recent.py && docker cp /tmp/count_recent.py google-workspace-mcp:/tmp/count_recent.py && docker exec google-workspace-mcp /app/.venv/bin/python /tmp/count_recent.py --since '$SINCE'" < "$GMAIL_SCRIPT" 2>&1)
  GMAIL_STATUS=$?
  if [ "$GMAIL_STATUS" -eq 0 ] && echo "$GMAIL_RAW" | tail -1 | grep -qE '^[0-9]+$'; then
    GMAIL_COUNT=$(echo "$GMAIL_RAW" | tail -1)
    echo "Gmail: $GMAIL_COUNT messages"
  else
    echo "::warning::Gmail count failed: $GMAIL_RAW"
  fi
else
  echo "::warning::count_recent.py not found at $GMAIL_SCRIPT — skipping Gmail count"
fi

MADDY_COUNT=-1
STALWART_COUNT=-1
# count-since.ts imports ../../shared/{imap,config}.js by relative path — those
# already exist in the deployed image at /app/mcp/shared/*.ts (cloud-mail-mcp's own
# tools import them the same way), so only the new file itself needs copying
# in, placed at the matching path under /app so the relative import — and
# node's node_modules walk-up to /app/node_modules for `imapflow` — resolve.
MAIL_SCRIPT="$REPO_ROOT/a_solutions/infra-api_cloud-mail-mcp/src/code/mcp/tools/others/count-since.ts"
if [ -f "$MAIL_SCRIPT" ]; then
  MAIL_RAW=$(ssh oci-apps "cat > /tmp/count-since.ts && docker exec cloud-mail-mcp mkdir -p /app/mcp/tools/others && docker cp /tmp/count-since.ts cloud-mail-mcp:/app/mcp/tools/others/count-since.ts && docker exec cloud-mail-mcp node /app/node_modules/tsx/dist/cli.mjs /app/mcp/tools/others/count-since.ts --since '$SINCE'" < "$MAIL_SCRIPT" 2>&1)
  MAIL_STATUS=$?
  MAIL_JSON=$(echo "$MAIL_RAW" | tail -1)
  if [ "$MAIL_STATUS" -eq 0 ] && echo "$MAIL_JSON" | jq -e . >/dev/null 2>&1; then
    MADDY_COUNT=$(echo "$MAIL_JSON" | jq -r '.maddy')
    STALWART_COUNT=$(echo "$MAIL_JSON" | jq -r '.stalwart')
    echo "maddy: $MADDY_COUNT messages · stalwart: $STALWART_COUNT messages"
  else
    echo "::warning::maddy/stalwart count failed: $MAIL_RAW"
  fi
else
  echo "::warning::count-since.ts not found at $MAIL_SCRIPT — skipping maddy/stalwart count"
fi

if [ "$GMAIL_COUNT" -ge 0 ]; then
  # A store count of -1 means the count never ran (SSH/docker failure above), not
  # that the store is empty. Reporting it as a divergence turns a transport blip
  # into a phantom "behind Gmail by $((GMAIL_COUNT + 1))" data-loss alarm.
  if [ "$MADDY_COUNT" -lt 0 ]; then
    echo "::error::maddy count unavailable — cannot reconcile against Gmail"
    FAIL_REASONS+=("maddy count unavailable (SSH/docker error) — reconciliation inconclusive")
  elif ! tolerance_ok "$GMAIL_COUNT" "$MADDY_COUNT"; then
    echo "::error::maddy diverges from Gmail: gmail=$GMAIL_COUNT maddy=$MADDY_COUNT"
    FAIL_REASONS+=("maddy behind Gmail by $((GMAIL_COUNT > MADDY_COUNT ? GMAIL_COUNT - MADDY_COUNT : MADDY_COUNT - GMAIL_COUNT)) messages (gmail=$GMAIL_COUNT maddy=$MADDY_COUNT)")
  fi
  if [ "$STALWART_COUNT" -lt 0 ]; then
    echo "::error::stalwart count unavailable — cannot reconcile against Gmail"
    FAIL_REASONS+=("stalwart count unavailable (SSH/docker error) — reconciliation inconclusive")
  elif ! tolerance_ok "$GMAIL_COUNT" "$STALWART_COUNT"; then
    echo "::error::stalwart diverges from Gmail: gmail=$GMAIL_COUNT stalwart=$STALWART_COUNT"
    FAIL_REASONS+=("stalwart behind Gmail by $((GMAIL_COUNT > STALWART_COUNT ? GMAIL_COUNT - STALWART_COUNT : STALWART_COUNT - GMAIL_COUNT)) messages (gmail=$GMAIL_COUNT stalwart=$STALWART_COUNT)")
  fi
  [ "$MADDY_COUNT" -ge 0 ] && [ "$STALWART_COUNT" -ge 0 ] && [ ${#FAIL_REASONS[@]} -eq 0 ] && echo "OK: all stores within tolerance of Gmail"
else
  echo "::warning::Gmail count unavailable — reconciliation skipped this run (liveness result still gates)"
fi

echo ""
echo "═══ Result ═══"

if [ ${#FAIL_REASONS[@]} -eq 0 ]; then
  echo "Mail Health OK ($PASSED/$TOTAL liveness checks passed; stores reconciled)"
  if [ -n "$BEARER" ]; then
    timeout 60 ssh -n $NTFY_SSH_OPTS oci-apps "curl -s --max-time 15 -X POST '$NTFY_URL/$NTFY_TOPIC' \
      -H 'Authorization: Bearer $BEARER' \
      -H 'Title: Mail Health OK ($PASSED/$TOTAL passed)' \
      -H 'Priority: 2' \
      -H 'Tags: white_check_mark,email' \
      -d 'All mail checks passed (liveness + cross-store reconciliation)'" || echo "::warning::ntfy notification failed or timed out (best-effort — result above stands)"
  fi
  exit 0
fi

echo "Mail Health FAILED:"
for r in "${FAIL_REASONS[@]}"; do echo "  - $r"; done

if [ -n "$BEARER" ]; then
  DETAIL=$(printf '%s\n' "${FAIL_REASONS[@]}")
  timeout 60 ssh -n $NTFY_SSH_OPTS oci-apps "curl -s --max-time 15 -X POST '$NTFY_URL/$NTFY_TOPIC' \
    -H 'Authorization: Bearer $BEARER' \
    -H 'Title: Mail Health FAILED' \
    -H 'Priority: 5' \
    -H 'Tags: rotating_light,email' \
    -d '$(printf '%s' "$DETAIL" | sed "s/'/'\\\\''/g")'" || echo "::warning::ntfy notification failed or timed out (best-effort — result above stands)"
else
  echo "::warning::no Authelia bearer token available — skipping ntfy alert (GitHub's own scheduled-workflow-failure email still fires)"
fi

exit 1
