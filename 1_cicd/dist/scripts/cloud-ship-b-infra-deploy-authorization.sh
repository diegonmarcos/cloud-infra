#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-b-infra-deploy-authorization.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔════════════════════════════════════════════════════════════════════╗
# ║ b_infra deploy-authorization gate                                  ║
# ║                                                                    ║
# ║ Decides, FAIL-CLOSED, whether a home-manager fleet deploy is        ║
# ║ authorised for the triggering GitHub event. Invoked by the Gate    ║
# ║ step of ship-home-manager.yml.                                      ║
# ║                                                                    ║
# ║ Why it exists (#414): before this gate, ANY commit touching        ║
# ║ b_infra/** shipped home-manager to ALL FOUR VMs unconditionally —  ║
# ║ recreating the agent containers on oci-apps and killing every      ║
# ║ running headless agent mid-task. A b_infra deploy is now           ║
# ║ deliberate: the triggering change must carry a required marker,    ║
# ║ or the run is refused BEFORE anything deploys.                     ║
# ║                                                                    ║
# ║ Required marker: every commit in the push that touches b_infra/**  ║
# ║ must include the marker string in its message; a manual            ║
# ║ workflow_dispatch must set the confirm_fleet_deploy input to true; ║
# ║ a workflow_run (gen-configs regeneration) must name the marker on  ║
# ║ its upstream head commit when that commit touched b_infra.         ║
# ║                                                                    ║
# ║ The marker is a rare, self-describing token so it cannot be typed  ║
# ║ by accident, and so a reviewer greps for it in one step.           ║
# ╚════════════════════════════════════════════════════════════════════╝
set -Eeuo pipefail

# The single source of truth for the required marker. Every layer that
# grants a b_infra deploy (this script's own checks, the documented rule,
# the tester) reads authorised only when this string is present.
REQUIRED_MARKER="${B_INFRA_DEPLOY_MARKER:?B_INFRA_DEPLOY_MARKER must be set}"
EVENT_NAME="${1:?event name required as argument 1}"
PAYLOAD_PATH="${2:?event payload path required as argument 2}"

fail_closed() {
    # Unconditional refusal, deliberately short and loud so a no-deploy run
    # can never be mistaken for a successful deploy.
    printf '::error::b_infra deploy REFUSED (fail-closed) — %s\n' "$*" >&2
    exit 1
}

[ -f "$PAYLOAD_PATH" ] || fail_closed "event payload $PAYLOAD_PATH is missing"

case "$EVENT_NAME" in
    push)
        # Every commit in the push that touches b_infra/** must carry the
        # marker. Iterating each commit (not just the head) closes the hole
        # where a b_infra change rides along in an earlier commit while the
        # marker sits on an unrelated later one.
        i=0
        while jq -e --argjson i "$i" '.commits[$i]' "$PAYLOAD_PATH" >/dev/null 2>&1; do
            # Commit touches b_infra/** iff any added/modified/removed path
            # starts with b_infra/. Emit one of those paths, or empty.
            # GitHub's push payload sets added/removed to NULL (not []) when a
            # commit only modifies files — the first real b_infra push
            # (74c17d50d, 2026-09-17) crashed this jq with "Cannot iterate
            # over null" and the gate never evaluated the marker. The
            # alternative-operator pattern must be ((.added) // [])[] — a bare
            # .added[] // empty still iterates the null and dies first.
            touched=$(jq -r --argjson i "$i" '
                ([((.commits[$i].added) // [])[],
                  ((.commits[$i].modified) // [])[],
                  ((.commits[$i].removed) // [])[]]
                 | map(select(startswith("b_infra/"))) | first // empty)' \
                "$PAYLOAD_PATH")
            if [ -n "$touched" ]; then
                msg=$(jq -r --argjson i "$i" '.commits[$i].message' "$PAYLOAD_PATH")
                if ! printf '%s' "$msg" | grep -qF -- "$REQUIRED_MARKER"; then
                    sha=$(jq -r --argjson i "$i" '.commits[$i].id' "$PAYLOAD_PATH")
                    fail_closed "commit $sha touches $touched but its message lacks the marker '$REQUIRED_MARKER'. Add the marker to authorise the fleet deploy."
                fi
            fi
            i=$((i + 1))
        done
        ;;

    workflow_dispatch)
        # Manual deploy: the operator must explicitly set the confirmation
        # input. A dispatch that leaves it unset is an accident, not intent.
        if [ "${3:-false}" != "true" ]; then
            fail_closed "workflow_dispatch ran without confirm_fleet_deploy=true. Set the input to authorise the fleet deploy."
        fi
        ;;

    workflow_run)
        # A regeneration run after gen-configs. A b_infra deploy via this path
        # carries the marker only if the upstream head commit (the one that
        # triggered gen-configs) named it. The orchestrating Gate step invokes
        # us only when that upstream commit touched b_infra (see the
        # path-relevance check it already performs). Require the marker so no
        # regeneration can slip an unmarked b_infra change past the push-path
        # gate under a second trigger.
        upstream_msg=$(jq -r '.workflow_run.head_commit.message // empty' "$PAYLOAD_PATH")
        if [ -z "$upstream_msg" ]; then
            fail_closed "workflow_run payload carries no upstream head commit message to authorise."
        fi
        if ! printf '%s' "$upstream_msg" | grep -qF -- "$REQUIRED_MARKER"; then
            fail_closed "workflow_run imports a b_infra change whose upstream commit lacks the marker '$REQUIRED_MARKER'. Add the marker to authorise the fleet deploy."
        fi
        ;;

    *)
        # An unknown or unmapped trigger must never deploy.
        fail_closed "unrecognised event '$EVENT_NAME' cannot authorise a b_infra deploy."
        ;;
esac

printf 'authorised\n'
