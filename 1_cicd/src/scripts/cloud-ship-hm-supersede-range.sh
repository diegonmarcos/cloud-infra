#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-hm-supersede-range.sh — what changed since the last     ║
# ║ home-manager run that actually covered the fleet?                  ║
# ║                                                                    ║
# ║ Usage:                                                             ║
# ║   cloud-ship-hm-supersede-range.sh base  <run_id>  < runs.json     ║
# ║     prints the head_sha of the newest OLDER run that covers its    ║
# ║     commit (in flight, or completed success, never a dispatch);    ║
# ║     prints nothing when there is none.                             ║
# ║   cloud-ship-hm-supersede-range.sh paths <run_id>                  ║
# ║     prints every path changed between that base and HEAD that the  ║
# ║     gate may act on: every non-b_infra path, plus b_infra paths    ║
# ║     ONLY from commits whose message carries B_INFRA_DEPLOY_MARKER  ║
# ║     (#414 consent is per commit, never inherited from a later one).║
# ║     exit 3 = range cannot be determined (no base, API or git       ║
# ║     failure); the caller then keeps the single-commit behaviour.   ║
# ║                                                                    ║
# ║ Why: ship-home-manager.yml keeps ONE pending run in its own        ║
# ║ concurrency group, so a newer run cancels an older queued one. The ║
# ║ gate used to look at HEAD^..HEAD only, so the newer run could skip ║
# ║ a VM whose relevant change lived in the cancelled run's commit     ║
# ║ (2026-10-14: 13 runs queued; the newest touched nothing a VM reads ║
# ║ and would have deployed nothing). Widening the diff to             ║
# ║ base..HEAD makes "newest pending run supersedes the older ones"    ║
# ║ true by construction. Test: 9_others/test/test_hm_supersede_range.sh║
# ╚════════════════════════════════════════════════════════════════════╝
set -Eeuo pipefail

MODE="${1:?mode required: base|paths}"
RUN_ID="${2:?run id required as argument 2}"

# Candidates for "already covered": runs OLDER than this one (ids grow
# monotonically) that are in flight (they ship their own commit before this
# run may start: one group, one run at a time) or that completed success.
# Cancelled/failed/skipped runs did not cover their commit, so their changes
# stay inside the range. workflow_dispatch runs never advance the base: a
# single-VM dispatch succeeds while shipping one VM only.
BASE_FILTER='[.workflow_runs[]
  | select(.id < $me)
  | select(.event != "workflow_dispatch")
  | select(.status != "completed" or .conclusion == "success")]
  | max_by(.id) | .head_sha // empty'

case "$MODE" in
  base)
    jq -r --argjson me "$RUN_ID" "$BASE_FILTER"
    ;;
  paths)
    MARKER="${B_INFRA_DEPLOY_MARKER:?B_INFRA_DEPLOY_MARKER must be set}"
    if [ -n "${HM_RANGE_RUNS_JSON:-}" ]; then
      runs=$(cat "$HM_RANGE_RUNS_JSON") || exit 3
    else
      : "${GH_TOKEN:?GH_TOKEN required to list runs}" "${GITHUB_REPOSITORY:?}"
      runs=$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/${HM_WORKFLOW_FILE:-ship-home-manager.yml}/runs?branch=main&per_page=100") \
        || { echo "::warning::supersede-range: cannot list runs" >&2; exit 3; }
    fi
    base=$(printf '%s' "$runs" | jq -r --argjson me "$RUN_ID" "$BASE_FILTER") || exit 3
    [ -n "$base" ] || { echo "::warning::supersede-range: no covering older run in the listing" >&2; exit 3; }
    head=$(git rev-parse HEAD)
    [ "$base" = "$head" ] && exit 0
    # The checkout is shallow; deepen until base is reachable (bounded).
    if ! git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
      git fetch -q --no-tags --deepen=300 origin "$head" 2>/dev/null || true
      git merge-base --is-ancestor "$base" HEAD 2>/dev/null \
        || { echo "::warning::supersede-range: base $base is not an ancestor of HEAD within reach" >&2; exit 3; }
    fi
    {
      git diff --name-only "$base" HEAD | grep -v '^b_infra/' || true
      git rev-list "$base..HEAD" -- b_infra | while IFS= read -r c; do
        if git log -1 --format=%B "$c" | grep -qF -- "$MARKER"; then
          git diff-tree --no-commit-id --name-only -r "$c" -- b_infra
        else
          echo "::notice::supersede-range: $c touches b_infra without '$MARKER' — not counted as consent" >&2
        fi
      done
    } | sort -u
    ;;
  *) echo "::error::supersede-range: unknown mode '$MODE'" >&2; exit 2 ;;
esac
