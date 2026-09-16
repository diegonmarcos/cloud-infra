#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Tester — dispatch runs on a scoped credential, never a universal ║
# ║ PAT  (#149 drop the universal dispatch PAT, #359 delete_repo)    ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   A) no file that performs a dispatch names a universal PAT      ║
# ║   B) the approved dispatch secret has no silent fallback         ║
# ║   C) every declared dispatch consumer still exists and still     ║
# ║      wires the approved secret  (dispatch did not silently die)  ║
# ║                                                                  ║
# ║ Policy is DATA, not code: 9_others/dispatch-policy.json.         ║
# ║ To ban another token name, to cover another file type, or to     ║
# ║ teach it another way of dispatching — edit that file, never this ║
# ║ one.                                                             ║
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

# ── Scan scope, read from the policy ───────────────────────────────────────
# Every one of these used to be a literal in this file. The old scope was three
# directories, -maxdepth 1, '*.yml' only — which is why a dispatch written in a
# .sh could reintroduce a banned universal PAT with the guard still green (#20).
mapfile -t SCAN_EXTS    < <(jq -r '.scan.file_extensions[]'  "$POLICY")
mapfile -t SCAN_PRUNE   < <(jq -r '.scan.exclude_dirs[]'     "$POLICY")
mapfile -t SCAN_MARKERS < <(jq -r '.scan.dispatch_markers[]' "$POLICY")

# An empty knob would make the whole scan vacuous — zero files examined, "PASS".
# That is the exact defect shape this ticket exists to remove, so it is fatal.
[ "${#SCAN_EXTS[@]}"    -gt 0 ] || { echo "::error::scan.file_extensions is empty in $POLICY — nothing would be read"; exit 1; }
[ "${#SCAN_MARKERS[@]}" -gt 0 ] || { echo "::error::scan.dispatch_markers is empty in $POLICY — no file would ever be in scope"; exit 1; }

_find_names=(); for _e in "${SCAN_EXTS[@]}";  do _find_names+=( -name "*.$_e" -o ); done; unset "_find_names[$(( ${#_find_names[@]} - 1 ))]"
_find_prune=(); for _d in "${SCAN_PRUNE[@]}"; do _find_prune+=( -name "$_d"   -o ); done; unset "_find_prune[$(( ${#_find_prune[@]} - 1 ))]"
_grep_markers=(); for _m in "${SCAN_MARKERS[@]}"; do _grep_markers+=( -e "$_m" ); done

# Roots: this whole repository, plus every declared consumer's tree. Consumers
# live in another repository (cloud-u-containers), and their dispatcher is the
# one file in the fleet whose ONLY job is to dispatch — leaving it out of A and
# B while asserting it in C would check the least interesting half.
scan_roots() {
    printf '%s\n' "$REPO_ROOT"
    local _n _i _cand _try _wf
    _n="$(jq -r '.dispatch_consumers | length' "$POLICY")"
    for _i in $(seq 0 $((_n - 1))); do
        _wf="$(jq -r ".dispatch_consumers[$_i].workflow" "$POLICY")"
        while IFS= read -r _cand; do
            [ -n "$_cand" ] || continue
            case "$_cand" in
                /*) _try="$_cand" ;;
                .)  _try="$REPO_ROOT" ;;
                *)  _try="$REPO_ROOT/$_cand" ;;
            esac
            [ -f "$_try/$_wf" ] && { printf '%s\n' "$_try"; break; }
        done < <(jq -r ".dispatch_consumers[$_i].checkout_paths[]?" "$POLICY")
    done
}

# Every file that actually SENDS a dispatch. `sort -u` because a consumer root
# can also sit inside the repo root (a_solutions is a submodule on the runner),
# and a file reported twice would be two failures for one defect.
dispatch_files() {
    local _root _f
    while IFS= read -r _root; do
        [ -d "$_root" ] || continue
        find "$_root" \( "${_find_prune[@]}" \) -prune -o -type f \( "${_find_names[@]}" \) -print 2>/dev/null
    done < <(scan_roots) | sort -u | while IFS= read -r _f; do
        grep -qF "${_grep_markers[@]}" -- "$_f" 2>/dev/null && printf '%s\n' "$_f"
    done
}

# Full-line comments only, blanked rather than deleted so line numbers survive.
# ship-reconcile.yml documents the old fallback in prose and dispatch-policy.json
# tells people to read it; a tester that cannot tell a binding from a comment
# about a binding forces the next person to delete the explanation to get green.
# `//` as well as `#` because ts/js are in scope now.
#
# Deliberately NOT stripping trailing comments: `curl ... # uses $BANNED` is the
# one place a trailing-comment stripper would hide a live credential, and an
# ALL-CAPS token name in the tail of a code line is worth a human look either way.
strip_comments() { sed -e 's|^[[:space:]]*#.*$||' -e 's|^[[:space:]]*//.*$||' -- "$1"; }

# The in-scope file list is computed ONCE. Recomputing it per section invited the
# two halves to drift apart, which is how a guard ends up asserting two different
# things while reporting one result.
mapfile -t DISPATCH_FILES < <(dispatch_files)

echo "── A: no file that performs a dispatch names a universal PAT ──"
printf "   scope: %s dispatching file(s) · extensions: %s · markers: %s\n" \
    "${#DISPATCH_FILES[@]}" \
    "$(IFS=,; printf '%s' "${SCAN_EXTS[*]}")" \
    "$(IFS=,; printf '%s' "${SCAN_MARKERS[*]}")"

mapfile -t BANNED < <(jq -r '.banned_for_dispatch[]' "$POLICY")
[ "${#BANNED[@]}" -gt 0 ] || fail "banned_for_dispatch is empty — the policy would pass anything"

# A guard whose scope collapses to zero passes everything. There is at least one
# real dispatcher in this fleet (ship-reconcile.yml) and there always will be, so
# an empty scope means the scan broke, not that the fleet stopped dispatching.
[ "${#DISPATCH_FILES[@]}" -gt 0 ] || fail "no dispatching file found under any scan root — the scan is vacuous and sections A and B are asserting nothing"

_a_hits=0
for f in "${DISPATCH_FILES[@]}"; do
    for b in "${BANNED[@]}"; do
        # Whole-word match on the bare NAME, not on `secrets.NAME`. The old test
        # looked for the GitHub Actions expression form only, so it was blind to
        # `$CGC_GHCR_PAT`, `${CGC_GHCR_PAT}`, `process.env.CGC_GHCR_PAT` and
        # `CGC_GHCR_PAT=...` — i.e. to every shape the name takes outside YAML.
        # These names are distinctive ALL-CAPS identifiers; any non-comment
        # occurrence inside a file that dispatches is worth failing on.
        while IFS= read -r _hit; do
            [ -n "$_hit" ] || continue
            # The LINE IS NOT PRINTED, only its number. This tester's whole
            # subject is credentials, and a hand-inlined literal is exactly the
            # case where echoing the offending line would put the secret in a
            # public job log.
            fail "${f#"$REPO_ROOT"/}:${_hit%%:*}: dispatching file names universal PAT '$b'"
            _a_hits=$((_a_hits + 1))
        done < <(strip_comments "$f" | grep -nE "\\b$b\\b" | cut -d: -f1 || true)
    done
done

[ "$_a_hits" -eq 0 ] && pass "no universal PAT named in any of the ${#DISPATCH_FILES[@]} dispatching file(s) (${#BANNED[@]} names checked)"

echo ""
echo "── B: the approved dispatch secret has no silent fallback ──"

# `secrets.APPROVED || secrets.SOMETHING_ELSE` is a silent downgrade: the
# dispatch keeps working, so CI stays green, while the credential actually in
# use is no longer the scoped one. That is how commit 329e41fec widened the
# dispatch path back to a classic PAT carrying delete_repo.
#
# `${APPROVED:-$SOMETHING_ELSE}` is the same downgrade written in shell, so it
# is flagged too — but `${APPROVED:-}` is not. An empty default is the guard
# ship-reconcile.yml uses to hard-fail on a missing token, which is the opposite
# of a silent fallback and must not be punished.
_b_hits=0
for f in "${DISPATCH_FILES[@]}"; do
    while IFS= read -r line; do
        case "$line" in
            *"$APPROVED"*"||"*)
                fail "${f#"$REPO_ROOT"/}: $APPROVED carries a '||' fallback"
                _b_hits=$((_b_hits + 1)) ;;
            *"$APPROVED"*":-"*)
                case "$line" in
                    *"$APPROVED:-}"*) ;;
                    *) fail "${f#"$REPO_ROOT"/}: $APPROVED carries a ':-' shell fallback"
                       _b_hits=$((_b_hits + 1)) ;;
                esac ;;
        esac
    done < <(strip_comments "$f" | grep -E "\\b$APPROVED\\b" || true)
done

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

    # And it must still actually dispatch something. Same markers section A uses,
    # so "is a dispatcher" means one thing in this file, not two.
    if grep -qF "${_grep_markers[@]}" -- "$_file"; then
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
