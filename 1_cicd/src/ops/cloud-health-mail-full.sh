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
#     store contents, so a store silently falling behind (e.g. maddy's
#     dual-write to Stalwart failing) goes undetected — this is exactly what
#     caused the 2026-08-11..08-20 silent mail-loss incident. This layer takes
#     every message Gmail (authoritative primary) received in the last 24h and
#     fails if more than tolerance of them are ABSENT from maddy or from
#     Stalwart, matched by Message-ID. Membership, not per-store counts: a
#     store stamps re-injected mail with its own arrival time, so counting what
#     each store "received in 24h" read the health_mail-reconcile DAG's
#     2026-09-14 repair of 146 old messages as "gmail=32 maddy=178
#     stalwart=181" for a day (details in count-since.ts). Reuses existing
#     scripts, no new clients/credentials:
#       - a_solutions/infra-api_google-workspace-mcp/src/code/gmail/count_recent.py --message-ids
#         (Gmail REST API via the container's service account, run via
#         `docker exec google-workspace-mcp`)
#       - a_solutions/infra-api_cloud-mail-mcp/src/code/mcp/tools/others/count-since.ts
#         (maddy IMAP + Stalwart JMAP, run via `docker exec cloud-mail-mcp`)
#     Both containers run on oci-apps (see each service's build.json
#     deploy.host). The Message-IDs are piped from one container into the other
#     ON oci-apps and never reach this job's log — only the counts come back.
#
# Requires (set up by the caller — see 1_cicd/src/cicd/health_mail_full.yml):
#   - SSH config alias `oci-apps` (same pattern as
#     1_cicd/src/cicd/cloud-health-reports.yml's "Setup SSH config" step)
#   - jq and tar on PATH (ubuntu-latest ships both)
# Optional:
#   - NTFY_URL — ntfy alert on pass/fail, same topic/headers/tags the working
#     dagu DAG health_mail-full.yaml already uses (unauthenticated: ntfy's
#     server.yml.tpl sets auth-default-access: read-write, and the dagu DAG's
#     own ntfy calls carry no Authorization header — see
#     a_solutions/infra-obs_dagu/src/dags/health_mail-full.yaml). Sending a
#     Bearer header here instead gets ntfy's OWN auth.db involved, which does
#     not recognise an Authelia-issued token and 401s ({"code":40101}) —
#     learned the hard way, do not re-add it. If NTFY_URL is unreachable the
#     alert is skipped with a warning but the check itself still exits
#     non-zero on failure, which GitHub's own scheduled-workflow-failure
#     email will surface either way.
#   - AUTHELIA_BEARER_TOKEN / AUTHELIA_TOKEN_URL / AUTHELIA_OIDC_CLIENT_ID /
#     AUTHELIA_OIDC_CLIENT_SECRET — feed BEARER_TOKEN into the liveness
#     report container (layer 1's own Authelia-gated internal checks), NOT
#     the ntfy alert. If unset, that report step fails its own auth-gated
#     probes rather than skipping anything ntfy-related.
set -uo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
REPORT_IMAGE="ghcr.io/diegonmarcos/cloud-data-reports:latest"
NTFY_URL="${NTFY_URL:-http://10.0.0.6:8090}"
NTFY_TOPIC="health_report_cloud-mail-health-full"
# Every SSH call below carries these. ConnectTimeout caps the handshake;
# ServerAlive* keeps a session that prints nothing for minutes (the reports
# container is silent while it runs) sending traffic, and kills a
# silently-dropped one after ~30s instead of letting it hang. Only the ntfy
# calls used to have them: without them the ntfy SSH once sat ~10min on a
# half-open mesh connection, and runs 34995321325 and 35022772131 both lost
# the liveness session ~5 minutes into its silence with "client_loop: send
# disconnect: Broken pipe" — the dead session then took the Gmail read with it.
# The `timeout 60` wrapper on each ntfy call stays the hard bound there.
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

# Mint a fresh client_credentials token where possible (same reasoning as
# a_solutions/infra-obs_dagu/src/dags/health_mail-full.yaml: a long-lived
# AUTHELIA_BEARER_TOKEN secret goes stale ~1h after mint). This BEARER feeds
# BEARER_TOKEN into the liveness report container below (layer 1) ONLY — it
# is deliberately never sent to ntfy (see the header comment). Falls back to
# a static AUTHELIA_BEARER_TOKEN if client-credentials env vars aren't set.
BEARER="${AUTHELIA_BEARER_TOKEN:-}"
if [ -n "${AUTHELIA_TOKEN_URL:-}" ] && [ -n "${AUTHELIA_OIDC_CLIENT_ID:-}" ] && [ -n "${AUTHELIA_OIDC_CLIENT_SECRET:-}" ]; then
  FRESH_TOKEN=$(curl -s --max-time 10 -X POST "$AUTHELIA_TOKEN_URL" \
    -u "$AUTHELIA_OIDC_CLIENT_ID:$AUTHELIA_OIDC_CLIENT_SECRET" \
    -d "grant_type=client_credentials&scope=authelia.bearer.authz" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
  [ -n "$FRESH_TOKEN" ] && BEARER="$FRESH_TOKEN"
fi

# Tolerance for cross-store reconciliation: a store may lack up to 2 of
# Gmail's last-24h messages OR 5%, whichever is larger — generous enough to
# absorb mail still in flight at the window edge (Gmail can hold a message a
# moment before maddy does), tight enough to catch a stalled dual-write within
# one run (checks run every 6h, well inside a day).
missing_allowance() {
  local reference="$1"
  local percent_allowance=$(( (reference * 5 + 99) / 100 ))  # ceil(5% of reference)
  echo $(( percent_allowance > 2 ? percent_allowance : 2 ))
}

FAIL_REASONS=()

# What layer 2 actually established this run. The pass path used to announce
# "stores reconciled" unconditionally, including on the branch where the Gmail
# count was unavailable and the whole comparison was skipped with a warning —
# so a run that verified nothing about cross-store consistency told the owner,
# by name, that it had. That is the exact shape of false green this layer was
# added to prevent, so the alert now reports the reconciliation that ran.
RECON_STATUS="cross-store reconciliation SKIPPED (Gmail reference unavailable)"

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
# `bash -s`, not a command string: the login shell of the SSH user on oci-apps
# is fish, which reads `set -e` as `set --erase`, prints an error and carries
# on. A failed report run then fell straight through to the `cat` of whatever
# cloud_mail_full.json an EARLIER run left in the volume, and SSH exited 0 —
# a stale report read as this run's result.
#
# $BEARER is forwarded into the container below as BEARER_TOKEN. Without it the
# reports entrypoint aborts with "FATAL: BEARER_TOKEN unset and no vault JWT
# found" — deliberately, so auth-gated probes never false-fail — and this whole
# layer reports "no valid cloud_mail_full.json produced".
RESULT_JSON=$(ssh $SSH_OPTS oci-apps bash -s <<EOF
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
EOF
) || { echo "::error::liveness report trigger failed (SSH/docker error)"; FAIL_REASONS+=("liveness report did not run"); RESULT_JSON=""; }

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
echo "═══ 2. Cross-store reconciliation (Gmail's last 24h, by Message-ID, in maddy and Stalwart) ═══"

SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)
echo "Window: since $SINCE"

GMAIL_COUNT=-1
MADDY_MISSING=-1
STALWART_MISSING=-1
GMAIL_SCRIPT="$REPO_ROOT/a_solutions/infra-api_google-workspace-mcp/src/code/gmail/count_recent.py"
MAIL_SCRIPT="$REPO_ROOT/a_solutions/infra-api_cloud-mail-mcp/src/code/mcp/tools/others/count-since.ts"
if [ -f "$GMAIL_SCRIPT" ] && [ -f "$MAIL_SCRIPT" ]; then
  # Both scripts travel in one tar stream (no local-file dependency on the
  # remote side — this checkout only exists on the GHA runner / dev machine),
  # then a second session runs them. count-since.ts is placed at the matching
  # path under /app so its relative ../../shared/{imap,config}.js imports —
  # already in the deployed image — and node's walk-up to /app/node_modules
  # for `imapflow` resolve. The remote script prints GMAIL_UNAVAILABLE when
  # the Gmail read itself fails, so that stays distinguishable from a store or
  # transport failure below.
  RECONCILE_OUTPUT=$(tar -cf - -C "$(dirname "$GMAIL_SCRIPT")" count_recent.py -C "$(dirname "$MAIL_SCRIPT")" count-since.ts \
    | ssh $SSH_OPTS oci-apps "mkdir -p /tmp/mail-health-reconcile && tar -xf - -C /tmp/mail-health-reconcile" 2>&1 \
    && ssh $SSH_OPTS oci-apps bash -s -- "$SINCE" <<'EOF' 2>&1
set -uo pipefail
since="$1"
staging=/tmp/mail-health-reconcile
docker cp "$staging/count_recent.py" google-workspace-mcp:/tmp/count_recent.py || exit 1
docker exec cloud-mail-mcp mkdir -p /app/mcp/tools/others || exit 1
docker cp "$staging/count-since.ts" cloud-mail-mcp:/app/mcp/tools/others/count-since.ts || exit 1
if ! message_ids=$(docker exec google-workspace-mcp /app/.venv/bin/python /tmp/count_recent.py --since "$since" --message-ids); then
  echo "GMAIL_UNAVAILABLE"
  exit 0
fi
printf '%s\n' "$message_ids" \
  | docker exec -i cloud-mail-mcp node /app/node_modules/tsx/dist/cli.mjs /app/mcp/tools/others/count-since.ts --since "$since"
EOF
  )
  RECONCILE_STATUS=$?
  RECONCILE_RESULT=$(printf '%s\n' "$RECONCILE_OUTPUT" | tail -1)
  if [ "$RECONCILE_STATUS" -eq 0 ] && [ "$RECONCILE_RESULT" = "GMAIL_UNAVAILABLE" ]; then
    # Not a skip: without the reference nothing about cross-store consistency
    # was verified. Passing here let a Gmail key the reader could not open turn
    # every run green while reconciling nothing.
    echo "::error::Gmail Message-ID read failed: $(printf '%s\n' "$RECONCILE_OUTPUT" | head -5)"
    FAIL_REASONS+=("Gmail reference unreadable — reconciliation did not run")
  elif [ "$RECONCILE_STATUS" -eq 0 ] && echo "$RECONCILE_RESULT" | jq -e . >/dev/null 2>&1; then
    # `jq -r` on a missing key prints the STRING "null", which makes the
    # `-lt 0` guards below a bash arithmetic error rather than a clean
    # "unavailable". Default and then assert an integer, so an unparseable
    # value lands on the -1 sentinel instead of leaking through as something
    # the tolerance check will treat as 0.
    GMAIL_COUNT=$(echo "$RECONCILE_RESULT" | jq -r '.gmail // -1')
    MADDY_MISSING=$(echo "$RECONCILE_RESULT" | jq -r '.maddy_missing // -1')
    STALWART_MISSING=$(echo "$RECONCILE_RESULT" | jq -r '.stalwart_missing // -1')
    [[ "$GMAIL_COUNT"      =~ ^-?[0-9]+$ ]] || GMAIL_COUNT=-1
    [[ "$MADDY_MISSING"    =~ ^-?[0-9]+$ ]] || MADDY_MISSING=-1
    [[ "$STALWART_MISSING" =~ ^-?[0-9]+$ ]] || STALWART_MISSING=-1
    echo "Gmail: $GMAIL_COUNT messages · missing from maddy: $MADDY_MISSING · missing from stalwart: $STALWART_MISSING"
  else
    # The Gmail read succeeded or never started, and then the run broke
    # (SSH/docker error, or count-since.ts crashed). Nothing was reconciled,
    # and a check that did not run must not look like one that passed.
    echo "::error::reconciliation run failed: $(printf '%s\n' "$RECONCILE_OUTPUT" | tail -5)"
    FAIL_REASONS+=("reconciliation did not run (SSH/docker error) — inconclusive")
  fi
else
  echo "::error::count_recent.py or count-since.ts not found under $REPO_ROOT/a_solutions — reconciliation cannot run"
  FAIL_REASONS+=("reconciliation scripts missing from the checkout — reconciliation did not run")
fi

if [ "$GMAIL_COUNT" -ge 0 ]; then
  ALLOWANCE=$(missing_allowance "$GMAIL_COUNT")
  # A missing count of -1 means that store could not be read, not that it is
  # empty. Reporting it as a divergence turns a transport blip into a phantom
  # "missing $GMAIL_COUNT messages" data-loss alarm.
  if [ "$MADDY_MISSING" -lt 0 ]; then
    echo "::error::maddy unreadable — cannot reconcile against Gmail"
    FAIL_REASONS+=("maddy unreadable (IMAP error) — reconciliation inconclusive")
  elif [ "$MADDY_MISSING" -gt "$ALLOWANCE" ]; then
    echo "::error::maddy is missing $MADDY_MISSING of Gmail's $GMAIL_COUNT messages (tolerance $ALLOWANCE)"
    FAIL_REASONS+=("maddy missing $MADDY_MISSING of Gmail's $GMAIL_COUNT messages from the last 24h")
  fi
  if [ "$STALWART_MISSING" -lt 0 ]; then
    echo "::error::stalwart unreadable — cannot reconcile against Gmail"
    FAIL_REASONS+=("stalwart unreadable (JMAP error) — reconciliation inconclusive")
  elif [ "$STALWART_MISSING" -gt "$ALLOWANCE" ]; then
    echo "::error::stalwart is missing $STALWART_MISSING of Gmail's $GMAIL_COUNT messages (tolerance $ALLOWANCE)"
    FAIL_REASONS+=("stalwart missing $STALWART_MISSING of Gmail's $GMAIL_COUNT messages from the last 24h")
  fi
  if [ "$MADDY_MISSING" -ge 0 ] && [ "$STALWART_MISSING" -ge 0 ] && [ ${#FAIL_REASONS[@]} -eq 0 ]; then
    echo "OK: both stores hold Gmail's messages within tolerance"
    RECON_STATUS="stores reconciled against Gmail (gmail=$GMAIL_COUNT missing: maddy=$MADDY_MISSING stalwart=$STALWART_MISSING)"
  fi
else
  echo "::error::Gmail reference unavailable — reconciliation did not run this run"
fi

echo ""
echo "═══ Result ═══"

if [ ${#FAIL_REASONS[@]} -eq 0 ]; then
  echo "Mail Health OK ($PASSED/$TOTAL liveness checks passed; $RECON_STATUS)"
  timeout 60 ssh -n $SSH_OPTS oci-apps "curl -s --max-time 15 -X POST '$NTFY_URL/$NTFY_TOPIC' \
    -H 'Title: Mail Health OK ($PASSED/$TOTAL passed)' \
    -H 'Priority: 2' \
    -H 'Tags: white_check_mark,email' \
    -d 'Liveness OK; $RECON_STATUS'" || echo "::warning::ntfy notification failed or timed out (best-effort — result above stands)"
  exit 0
fi

echo "Mail Health FAILED:"
for r in "${FAIL_REASONS[@]}"; do echo "  - $r"; done

DETAIL=$(printf '%s\n' "${FAIL_REASONS[@]}")
timeout 60 ssh -n $SSH_OPTS oci-apps "curl -s --max-time 15 -X POST '$NTFY_URL/$NTFY_TOPIC' \
  -H 'Title: Mail Health FAILED' \
  -H 'Priority: 5' \
  -H 'Tags: rotating_light,email' \
  -d '$(printf '%s' "$DETAIL" | sed "s/'/'\\\\''/g")'" || echo "::warning::ntfy notification failed or timed out (best-effort — result above stands)"

exit 1
