#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-registry-digest.sh — what digest does <ref> name RIGHT NOW?    ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# WHY THIS EXISTS (#358)
#
# Both digest engines — cloud-ship-reconcile.sh and the `status` verb in
# cloud-ship-container-step-status.sh — have to answer the same question, and
# both were answering it with a credential that CANNOT read half the fleet.
#
# Three of the fleet's packages are PRIVATE and linked to their own source
# repos, not to cloud-infra: kg-store-binaries, session-memory-binaries and
# cf-worker-http-to-wg-public-bridge-binaries. ghcr.io issues no anonymous pull
# token for them and refuses this repo's GITHUB_TOKEN, so every sweep reported
# them `undecidable`. Measured 2026-09-16, all three were in fact perfectly
# in-sync — the engine simply could not see them. An undecidable service is an
# unmonitored service, so this was three services with no drift detection at
# all, reported as a shrug rather than as a gap.
#
# WHY THE VM'S OWN CREDENTIAL, AND NOT A PAT
#
# The obvious fix is a token with read:packages. The obvious token is
# CGC_GHCR_PAT, and it is the WRONG one: #359 removed exactly that fallback
# from ship-reconcile.yml's dispatch step because, inspected on 2026-09-16, it
# is a universal CLASSIC PAT carrying admin:enterprise, admin:org, repo AND
# delete_repo. Re-introducing it here — so a read-only watchdog can read a
# manifest — would hand a repo-deleting credential to a scheduled job, and
# would undo a deliberate, documented narrowing two commits later.
#
# The narrowest credential that can answer already exists and is already in the
# right place: the VM is logged in to ghcr.io and PULLED the image in the
# first place. If it can pull the image, it can read the image's digest. So the
# question is asked ON the VM, over the SSH channel both engines already hold,
# and only the digest comes back. The credential never crosses the wire and is
# never printed. Verified on oci-apps 2026-09-16: all three private packages
# resolve this way.
#
# It is also more CORRECT, not merely better-scoped. `:latest` may be a
# multi-arch index, and the digest a container records depends on how that VM
# pulled it. Asking the VM that runs the container is asking the machine whose
# answer actually decides the verdict.
#
# WHY NOT `docker manifest inspect` ON THE VM
#
# Tried first, because it needs no token handling at all. It is wrong for
# multi-arch: for an index, `docker manifest inspect -v` returns ONLY the
# per-arch child descriptors and never the index digest itself — while a
# `docker pull` of that same tag records the INDEX digest in RepoDigests.
# Comparing against children alone reports a correct multi-arch deploy as
# DRIFT. Measured on ghcr.io/diegonmarcos/cloud-data-reports:latest: children
# 3cae861f / 0253c344, index 9e0c1f4e — the running digest would be 9e0c1f4e
# and would match neither child. The registry's own Docker-Content-Digest
# header is the only source that states the index digest, so the HTTP path
# stays, and only the credential moves.
#
# CONTRACT
#
#   argv   : <image_ref> [vm_alias]
#   stdout : every digest that legitimately identifies <ref> right now, one per
#            line — the index/manifest digest AND each per-arch child digest.
#            Both are needed: depending on how the VM pulled, a container's
#            RepoDigest records either.
#   stderr : nothing on success. A credential is NEVER echoed to either stream.
#   exit 0 : always, including "could not read it". An empty stdout means
#            UNDECIDABLE and the caller must treat it as such — never as
#            in-sync. Exiting non-zero here would abort a fleet sweep over one
#            unreadable image, which is the failure mode #354 already paid for.

set -uo pipefail

REF="${1:-}"
VM="${2:-}"
[ -n "$REF" ] || exit 0

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

# A digest-pinned ref names its own digest; there is nothing to ask anyone.
# Handled here as well as in the callers so this script is correct standalone.
case "$REF" in
  *@sha256:*) printf 'sha256:%s\n' "${REF##*@sha256:}"; exit 0 ;;
esac

_path="${REF#*/}"                 # ghcr.io/owner/name:tag -> owner/name:tag
_tag="${_path##*:}"
_repo="${_path%:*}"
[ "$_tag" = "$_path" ] && _tag="latest"

# This string is interpolated into a command that runs on a remote shell. A ref
# comes from a container's own Config.Image, which is not attacker-controlled
# today — but "not attacker-controlled today" is not a property that survives
# refactoring, and the cost of asserting it here is one line.
case "$_repo$_tag" in
  *[!A-Za-z0-9./_-]*)
    printf 'refusing to resolve a ref with shell-unsafe characters: %s\n' "$REF" >&2
    exit 0 ;;
esac

_url="https://ghcr.io/v2/$_repo/manifests/$_tag"

# Emit index/manifest digest + every child, given a bearer token. Used by the
# local-credential path; the VM path runs its own copy remotely.
_emit_local() {
  curl -sSI -H "Authorization: Bearer $1" -H "Accept: $ACCEPT" "$_url" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}'
  curl -sS  -H "Authorization: Bearer $1" -H "Accept: $ACCEPT" "$_url" 2>/dev/null \
    | jq -r '(.manifests // [])[].digest' 2>/dev/null
}

# ── 1. The VM's own pull credential, used on the VM ───────────────────────
# Sent over stdin to `bash -s` rather than as an argument string. Two reasons,
# both already paid for elsewhere in this engine: oci-apps' login shell is
# fish, and Go/jq brace syntax does not survive the sh->ssh->fish quoting
# layers (see probe_vm_real); and `bash -s` itself is brace-free so fish passes
# it through untouched. Feeding ssh an explicit heredoc also stops it from
# eating the CALLER's stdin — reconcile calls this from inside a
# `while read` loop, and an ssh that inherits that loop's stdin swallows the
# remaining findings. That bug is already commented twice in this engine.
if [ -n "$VM" ]; then
  _out="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$VM" 'bash -s' 2>/dev/null <<REMOTE || true
set -uo pipefail
auth=\$(jq -r '.auths["ghcr.io"].auth // empty' ~/.docker/config.json 2>/dev/null)
[ -n "\$auth" ] || exit 0
tok=\$(curl -sS -H "Authorization: Basic \$auth" \\
        "https://ghcr.io/token?scope=repository:$_repo:pull&service=ghcr.io" 2>/dev/null \\
      | jq -r '.token // empty' 2>/dev/null)
[ -n "\$tok" ] || exit 0
curl -sSI -H "Authorization: Bearer \$tok" -H "Accept: $ACCEPT" "$_url" 2>/dev/null \\
  | tr -d '\r' | awk -F': ' 'tolower(\$1)=="docker-content-digest" {print \$2}'
curl -sS  -H "Authorization: Bearer \$tok" -H "Accept: $ACCEPT" "$_url" 2>/dev/null \\
  | jq -r '(.manifests // [])[].digest' 2>/dev/null
REMOTE
)"
  _out="$(printf '%s\n' "$_out" | grep '^sha256:' | sort -u || true)"
  [ -n "$_out" ] && { printf '%s\n' "$_out"; exit 0; }
fi

# ── 2. GH_TOKEN, then anonymous ───────────────────────────────────────────
# Both only ever reach PUBLIC packages (and, for GH_TOKEN, packages linked to
# this repo). Kept because they need no VM: an operator running `status`
# against a public image, and the tester, both work with no mesh at all.
#
# CGC_GHCR_PAT is deliberately NOT in this ladder. See the header.
for _cred in "${GH_TOKEN:-}" ""; do
  if [ -n "$_cred" ]; then
    _tok="$(curl -sS -u "x:$_cred" "https://ghcr.io/token?scope=repository:$_repo:pull&service=ghcr.io" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)"
  else
    _tok="$(curl -sS "https://ghcr.io/token?scope=repository:$_repo:pull&service=ghcr.io" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)"
  fi
  [ -n "${_tok:-}" ] || continue
  # A token that cannot actually read the manifest is no better than none.
  [ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_tok" -H "Accept: $ACCEPT" "$_url" 2>/dev/null)" = "200" ] || continue
  _out="$(_emit_local "$_tok" | grep '^sha256:' | sort -u || true)"
  [ -n "$_out" ] && { printf '%s\n' "$_out"; exit 0; }
done

# Nothing could read it. Empty stdout, exit 0 — the caller reports UNDECIDABLE.
exit 0
