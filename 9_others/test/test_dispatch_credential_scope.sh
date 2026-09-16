#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Tester — dispatch runs on a scoped credential, never a universal ║
# ║ PAT  (#149 drop the universal dispatch PAT, #359 delete_repo)    ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) no dispatch credential binding names a universal PAT        ║
# ║   B) the approved dispatch secret has no `||` fallback           ║
# ║   C) every declared dispatch consumer still exists and still     ║
# ║      wires the approved secret  (dispatch did not silently die)  ║
# ║                                                                  ║
# ║ Policy is DATA, not code: 9_others/dispatch-policy.json.         ║
# ║ To ban another token name, edit that file — never this one.      ║
# ║                                                                  ║
# ║ Usage: bash 9_others/test/test_dispatch_credential_scope.sh      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at different
# depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
POLICY="$REPO_ROOT/9_others/dispatch-policy.json"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "::error::jq is required by this tester"; exit 1; }
[ -f "$POLICY" ] || { echo "::error::policy file missing: $POLICY"; exit 1; }

APPROVED="$(jq -r '.approved_secret' "$POLICY")"
[ -n "$APPROVED" ] && [ "$APPROVED" != "null" ] || { echo "::error::approved_secret unset in $POLICY"; exit 1; }

# A credential binding is `SOMETHING_TOKEN: ${{ ... }}` or `SOMETHING_PAT: ${{ ... }}`
# in a workflow's env block. That is the only shape through which a GHA secret
# can reach the shell that performs a dispatch.
CRED_BINDING='^[[:space:]]*[A-Z_]*(TOKEN|PAT)[[:space:]]*:[[:space:]]*\$\{\{'

# Workflow trees to scan. src/ is the source of truth; dist/ and
# .github/workflows/ are generated from it, and are scanned too because a
# hand-edit landing only in the generated copy is precisely how a banned
# credential would slip back in unnoticed.
WF_DIRS=("$REPO_ROOT/1_cicd/src/cicd" "$REPO_ROOT/1_cicd/dist" "$REPO_ROOT/.github/workflows")

workflow_files() {
    local d
    for d in "${WF_DIRS[@]}"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -name '*.yml' -type f
    done
}

echo "── A: no dispatch credential binding names a universal PAT ──"

mapfile -t BANNED < <(jq -r '.banned_for_dispatch[]' "$POLICY")
[ "${#BANNED[@]}" -gt 0 ] || fail "banned_for_dispatch is empty — the policy would pass anything"

_a_hits=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Only files that actually perform a dispatch are in scope. CGC_GHCR_PAT is
    # the correct credential for ghcr.io package reads (cgc-db-index.yml), and
    # banning it repo-wide would be wrong — this is about the DISPATCH path.
    grep -q '/dispatches' "$f" || continue

    # Strip comments: ship-reconcile.yml documents the old fallback in prose,
    # and a tester that cannot tell a binding from a comment about a binding
    # would force the next person to delete the explanation to get green.
    while IFS= read -r line; do
        for b in "${BANNED[@]}"; do
            if printf '%s' "$line" | grep -q "secrets\.$b\b"; then
                fail "$(basename "$f"): dispatch credential binding names universal PAT '$b' → $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
                _a_hits=$((_a_hits + 1))
            fi
        done
    done < <(sed 's/#.*$//' "$f" | grep -E "$CRED_BINDING" || true)
done < <(workflow_files)

[ "$_a_hits" -eq 0 ] && pass "no universal PAT bound in any dispatch credential (${#BANNED[@]} names checked)"

echo ""
echo "── B: the approved dispatch secret has no silent fallback ──"

# `secrets.APPROVED || secrets.SOMETHING_ELSE` is a silent downgrade: the
# dispatch keeps working, so CI stays green, while the credential actually in
# use is no longer the scoped one. That is how commit 329e41fec widened the
# dispatch path back to a classic PAT carrying delete_repo.
_b_hits=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in
            *"secrets.$APPROVED"*"||"*)
                fail "$(basename "$f"): $APPROVED carries a '||' fallback → $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
                _b_hits=$((_b_hits + 1))
                ;;
        esac
    done < <(sed 's/#.*$//' "$f" | grep -E "$CRED_BINDING" || true)
done < <(workflow_files)

[ "$_b_hits" -eq 0 ] && pass "$APPROVED is used without a fallback everywhere it appears"

echo ""
echo "── C: every declared dispatch consumer is still wired ──"

# The failure this guards against is the opposite of a leak and worse for the
# fleet: a dispatch that quietly stops firing. Pushes keep succeeding, the
# workflow keeps going green, and nothing deploys. cloud-u-containers already
# carries a comment about the 2026-08-24 false-green that left c3-public-api
# undeployed; this makes the wiring itself an asserted contract.
_n_consumers="$(jq -r '.dispatch_consumers | length' "$POLICY")"
[ "$_n_consumers" -gt 0 ] || fail "dispatch_consumers is empty — nothing is being asserted"

for i in $(seq 0 $((_n_consumers - 1))); do
    _repo="$(jq -r ".dispatch_consumers[$i].repo" "$POLICY")"
    _wf="$(jq -r ".dispatch_consumers[$i].workflow" "$POLICY")"

    # Resolve the consumer's tree from the declared candidates. No silent skip:
    # if none resolve, that is a FAILURE, not a pass with a shrug.
    _root=""
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        case "$cand" in
            /*) _try="$cand" ;;
            .)  _try="$REPO_ROOT" ;;
            *)  _try="$REPO_ROOT/$cand" ;;
        esac
        if [ -f "$_try/$_wf" ]; then _root="$_try"; break; fi
    done < <(jq -r ".dispatch_consumers[$i].checkout_paths[]?" "$POLICY")

    if [ -z "$_root" ]; then
        _cands="$(jq -r ".dispatch_consumers[$i].checkout_paths[]?" "$POLICY" | tr '\n' ' ')"
        fail "$_repo: could not find '$_wf' under any of: $_cands — cannot prove this dispatcher still exists"
        continue
    fi

    _file="$_root/$_wf"
    if grep -q "secrets\.$APPROVED\b" "$_file"; then
        pass "$_repo: $_wf wires $APPROVED"
    else
        fail "$_repo: $_wf no longer references $APPROVED — cross-repo dispatch may be dead (silent no-op, green run, nothing deployed)"
    fi

    # And it must still actually dispatch something.
    if grep -qE '/dispatches|repos/[^ ]*/dispatches' "$_file"; then
        pass "$_repo: $_wf still calls a dispatch endpoint"
    else
        fail "$_repo: $_wf contains no dispatch endpoint call — the dispatcher was gutted"
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "dispatch credential scope: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "dispatch credential scope: FAIL"
    echo "  policy: 9_others/dispatch-policy.json"
    echo "══════════════════════════════════════════════"
    exit 1
fi
