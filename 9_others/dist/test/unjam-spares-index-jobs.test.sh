#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/unjam-spares-index-jobs.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# unjam-ship.yml must never cancel a cgc-db INDEX job: those run for hours outside the
# ship-wg-runner group. Run 39636567781 lost its cloud-u-android graphrag job to an unjam
# with stale_minutes=5 (#1061). Extracts WG_JOB_FILTER from the workflow and feeds it jobs.
set -uo pipefail
ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
Y="$ROOT/1_cicd/src/cicd/unjam-ship.yml"
FAIL=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; FAIL=1; }
F=$(sed -n "s/^ *WG_JOB_FILTER='\(.*\)'\$/\1/p" "$Y")
[ -n "$F" ] || { bad "WG_JOB_FILTER not found in $Y"; exit 1; }
run() { printf '%s' "$1" | jq -r "$F"; }
J() { printf '{"jobs":[{"name":"%s","status":"%s","started_at":"%s"}]}' "$1" "$2" "$3"; }
T=2026-10-21T16:38:00Z
[ -z "$(run "$(J 'phase · graphrag / cgc-db · graphrag · cloud-u-android' in_progress $T)")" ] && ok "graphrag index job is spared" || bad "graphrag index job would be cancelled"
[ -z "$(run "$(J 'phase · semantic → graphrag (per repo) / cgc-db · both · cloud-infra' in_progress $T)")" ] && ok "two-phase index job is spared" || bad "two-phase index job would be cancelled"
[ -z "$(run "$(J 'coalesce · newer scheduled run queued?' in_progress $T)")" ] && ok "coalesce job is spared" || bad "coalesce job would be cancelled"
[ "$(run "$(J 'phase · graphrag / cgc-db · graphrag · restore-all → oci-apps' in_progress $T)")" = "$T" ] && ok "restore-all (holds the group) is eligible" || bad "restore-all not eligible"
[ "$(run "$(J 'Ship via cloud-builder' in_progress $T)")" = "$T" ] && ok "a ship job is eligible" || bad "ship job not eligible"
[ -z "$(run "$(J 'Ship via cloud-builder' completed $T)")" ] && ok "a finished job is ignored" || bad "finished job counted"
M='{"jobs":[{"name":"phase · graphrag / cgc-db · graphrag · cloud-u-android","status":"in_progress","started_at":"2026-10-21T10:00:00Z"},{"name":"restore-all → oci-apps","status":"in_progress","started_at":"2026-10-21T14:00:00Z"}]}'
[ "$(run "$M")" = "2026-10-21T14:00:00Z" ] && ok "mixed run is aged by its group-holding job only" || bad "mixed run aged by the index job"
grep -q 'only index/gating jobs in progress' "$Y" && ok "the loop skips runs with only index jobs" || bad "loop does not use the filter"
exit "$FAIL"
