#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-health-mail-failure-classifier.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Failure classifier for cloud-health-mail-full.sh ──
# Sourced, never executed. Turns the (exit status, captured output) pair of a
# layer that ended badly into the cause that actually ended it.
#
# Why this exists (#398): the reporter used to append one hardcoded string,
# "SSH/docker error", on EVERY non-zero outcome of every layer. That string was
# not a diagnosis, it was a shrug — it was appended without looking at the
# output, and on the liveness layer the output was not even captured, because
# the remote stderr went straight to the job log and only the exit status came
# back. So a maddy that had stopped accepting mail, an image that would not
# pull, a crashed probe script and a dropped mesh connection all produced the
# same sentence in the report and the same words in the ntfy alert. Every one
# of those needs a different person to do a different thing, and the two most
# common of them are not mail faults at all.
#
# Two functions, both reading 9_others/mail-health-diagnosis.json — the rules
# are data so that adding a newly-seen failure string is an entry in a file and
# not another elif in a script:
#
#   mail_health_classify <exit_status> <evidence>
#       prints "class<TAB>id<TAB>label" for the first matching rule.
#
#   mail_health_record_failure <layer> <exit_status> <evidence>
#       classifies, then routes: class "transport" into TRANSPORT_FAILURES
#       (the check never reached the mail stack — the mail verdict is UNKNOWN),
#       everything else into FAIL_REASONS (the mail stack answered badly).
#       Only the label is printed. The evidence may carry recipient addresses
#       from an SMTP reply, so it is classified and dropped, never echoed.
#
# Deliberately sets no shell options: a sourced library that changes its
# caller's options is a trap for the next consumer. Both callers run under
# `set -u` already.

MAIL_HEALTH_DIAGNOSIS_JSON="${MAIL_HEALTH_DIAGNOSIS_JSON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/9_others/mail-health-diagnosis.json}"

# The hardened SSH invocation, declared once in the same file as the rules that
# name what happens when it fails anyway. Printed one option per line.
mail_health_ssh_options() {
    jq -r '.ssh_options[]' "$MAIL_HEALTH_DIAGNOSIS_JSON"
}

mail_health_classify() {
    local exit_status="$1" evidence="$2"
    local id class label pattern want_status

    [ -f "$MAIL_HEALTH_DIAGNOSIS_JSON" ] || {
        printf 'unknown\trules-file-missing\t%s is not in the checkout — every failure below is unclassified\n' \
            "$MAIL_HEALTH_DIAGNOSIS_JSON"
        return 1
    }

    # "-" is the absent marker: jq's @tsv cannot carry a null, and an empty
    # field would be indistinguishable from a rule that matches everything.
    while IFS=$'\t' read -r id class label pattern want_status; do
        [ -n "$id" ] || continue
        [ "$want_status" = "-" ] || [ "$want_status" = "$exit_status" ] || continue
        if [ "$pattern" != "-" ]; then
            printf '%s' "$evidence" | grep -Eqi -- "$pattern" || continue
        fi
        printf '%s\t%s\t%s\n' "$class" "$id" "$label"
        return 0
    done < <(jq -r '.failure_causes[] | [.id, .class, .label, (.pattern // "-"), (.exit_status // "-" | tostring)] | @tsv' "$MAIL_HEALTH_DIAGNOSIS_JSON")

    # Reachable only if someone deletes the terminal fallback rule. Saying so is
    # the point: silently returning "transport" or "mail" here would put a
    # made-up cause in the alert, which is the defect this file exists to undo.
    printf 'unknown\tno-rule-matched\tno rule matched and the rule set has no terminal fallback — repair 9_others/mail-health-diagnosis.json\n'
    return 1
}

mail_health_record_failure() {
    local layer="$1" exit_status="$2" evidence="$3"
    local class id label
    IFS=$'\t' read -r class id label < <(mail_health_classify "$exit_status" "$evidence")

    if [ "$class" = "transport" ]; then
        TRANSPORT_FAILURES+=("$layer: $label [$id]")
        echo "::error::$layer — TRANSPORT FAILURE: $label [$id]"
    else
        FAIL_REASONS+=("$layer: $label [$id]")
        echo "::error::$layer — $label [$id]"
    fi
}
