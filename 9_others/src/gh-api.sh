#!/usr/bin/env bash
# Fleet continuous-integration reader. The gh(1) command line tool is not
# installed in the agent containers; this is the REST equivalent every agent
# uses to prove a run is green.
#
# usage:
#   gh-api.sh runs  <owner/repo> [per_page]   -> recent runs
#   gh-api.sh fails <owner/repo> [per_page]   -> only failing/cancelled/timed_out runs
#   gh-api.sh jobs  <owner/repo> <run_id>     -> every job and EVERY step, with its conclusion
#   gh-api.sh log   <owner/repo> <job_id>     -> raw job log
#
# Why `jobs` prints every step, and why silence is now fatal (ticket #400):
#
# This subcommand used to print each job plus ONLY the steps whose conclusion
# was neither success nor skipped. Three completely different outcomes therefore
# rendered as the same thing — one "JOB ... => success" line and nothing else:
#
#   1. a run where every step really passed,
#   2. a run where every step was SKIPPED and nothing was built at all
#      (cloud-infra Ship 35069355373, 2026-09-16: change detection mapped the
#      commit to no deployable container, so Build, Deploy, Collect traces and
#      Deploy gate all skipped while the run still concluded "success"),
#   3. a run this tool never actually inspected — a run identifier that does not
#      exist in the repository named produced a bare jq error on standard error
#      and still exited zero.
#
# An empty listing was thus the output for "all good", "nothing happened" and
# "never looked". Every "I watched it to green" claim made through this tool was
# unverified. The fix is in both directions: the listing you do see is now the
# complete one, and an absence of steps — zero jobs, zero steps, an HTTP error,
# a missing token — is a loud non-zero failure instead of a clean empty page.
set -uo pipefail

API="https://api.github.com/repos"

usage() {
    cat >&2 <<'USAGE_EOF'
usage: gh-api.sh runs|fails <owner/repo> [per_page]
       gh-api.sh jobs       <owner/repo> <run_id>
       gh-api.sh log        <owner/repo> <job_id>
USAGE_EOF
    exit 2
}

# Every failure path in this script goes through here: one prefix, standard
# error, non-zero. Nothing in this tool is allowed to report a problem by
# printing nothing.
die() { printf 'gh-api.sh: FAILURE: %s\n' "$*" >&2; exit 1; }

# One authenticated GET. Dies on a transport error and on any non-200 status,
# because a 401/403/404 body is not a listing — it is the tool telling you it
# never saw the run you asked about.
api_get() { # api_get <url>  ->  response body on standard output
    _response="$(curl -sS -w $'\n%{http_code}' \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$1")" || die "curl could not reach $1"
    _code="${_response##*$'\n'}"
    _body="${_response%$'\n'*}"
    if [ "$_code" != "200" ]; then
        _message="$(printf '%s' "$_body" | jq -r '.message? // empty' 2>/dev/null)"
        die "HTTP $_code from $1${_message:+ — $_message}. Nothing was read, so nothing is proven."
    fi
    printf '%s' "$_body"
}

[ "$#" -ge 2 ] || usage
command -v jq >/dev/null || die "jq is required to read the GitHub API responses"

# An unauthenticated call does not fail cleanly: against a public repository it
# returns a rate-limited 200 or a 404 that reads like "no such run", and against
# a private one a 404 that reads exactly the same. Refuse before asking.
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is empty — this call would be unauthenticated, and an unauthenticated answer cannot prove a run is green"

case "$1" in
    runs|fails)
        api_get "$API/$2/actions/runs?per_page=${3:-30}" | jq -r --arg mode "$1" '
            .workflow_runs[]
            | select($mode == "runs" or (.conclusion | . != "success" and . != null and . != "skipped"))
            | [.id, .name, .head_branch, .status, (.conclusion // "-"), .created_at, .event] | @tsv' ;;
    jobs)
        [ "$#" -ge 3 ] || usage
        _url="$API/$2/actions/runs/$3/jobs?per_page=100"
        _body="$(api_get "$_url")" || exit 1

        _jobs_count="$(printf '%s' "$_body" | jq '.jobs | length' 2>/dev/null)" \
            || die "the response for run $3 in $2 is not the job listing this tool expects"
        [ "${_jobs_count:-0}" -gt 0 ] || die \
            "run $3 in $2 reported ZERO jobs. Run identifiers are per-repository — a run triggered by one repository's push can live in another repository's Actions. This is not a green run, it is a run that was never read."

        # Counted across all jobs, because one job with steps does not excuse a
        # sibling that has none: a job still queued has not run its steps yet,
        # and "not yet" is not "passed".
        _steps_count="$(printf '%s' "$_body" | jq '[.jobs[] | (.steps // []) | length] | add // 0')"
        [ "${_steps_count:-0}" -gt 0 ] || die \
            "run $3 in $2 has $_jobs_count job(s) but ZERO steps. The run is queued, or its jobs never started. Either way no step has a conclusion, so nothing here proves anything."

        # EVERY step, with its conclusion. No filter: the caller is reading this
        # to decide whether their commit built, and "skipped" is the answer that
        # used to be invisible.
        printf '%s' "$_body" | jq -r '
            .jobs[]
            | "JOB \(.id) \(.name) => \(.conclusion // .status)",
              (.steps[]? | "    step \(.number) \(.name) => \(.conclusion // .status)")'
        printf '── %s job(s), %s step(s) listed — every step above is shown with its conclusion ──\n' \
            "$_jobs_count" "$_steps_count" ;;
    log)
        [ "$#" -ge 3 ] || usage
        curl -sSL --fail-with-body \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "$API/$2/actions/jobs/$3/logs" \
            || die "could not fetch the log for job $3 in $2" ;;
    *) usage ;;
esac
