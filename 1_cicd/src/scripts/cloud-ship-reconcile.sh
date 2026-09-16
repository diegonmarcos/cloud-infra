#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-reconcile.sh — deployed state vs GHCR, per service, per VM     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# WHY THIS EXISTS (#354)
#
# `detect` in ship.yml ships only the commit range the dispatch announced. The
# fleet-wide `ship-wg-runner` concurrency group holds exactly ONE pending run,
# so a deploy that queues behind a busy runner is EVICTED — GitHub marks it
# `cancelled`, grey, no notification. Nothing re-queues it. No later commit
# touches that service, so its next chance to deploy never arrives, and every
# run in the list stays green while the fleet runs old code. That is how the
# infra-obs_dagu DAG fix (#114, commits ecff144a / 1bdd8c3c) sat undeployed for
# four weeks behind runs 34320673387 and 34323561146, whose `Deploy → oci-apps`
# jobs (102368219642, 102376851339) were both evicted.
#
# The commit range is the wrong source of truth. A commit range answers "what
# changed since last time", and "last time" is exactly the thing an evicted
# deploy destroyed. The fleet's own state answers "what is actually running",
# which no eviction can falsify. This script asks the second question.
#
# WHY DIGESTS AND NOT A DEPLOY LEDGER
#
# A ledger records what the engine BELIEVES it deployed. The failure mode here
# is the engine believing wrongly, so a ledger would have to be trusted exactly
# where it is least trustworthy. The running container's image digest is
# observed, not asserted: it is what the VM will still say after the run list,
# the ledger and the health page have all been wrong.
#
# It also needs no bootstrap. A stamp-based design would report "unknown" for
# every service until each had been deployed once THROUGH the new code, which
# means the live #352 casualty would not be nameable today. Digests name it now.
#
# WHAT IT DOES NOT COVER (stated, not hidden)
#
# Config-only drift where dist/ changed but the app image did not. The deploy
# extracts ghcr.io/<owner>/<service>-configs:latest into the VM's remote_path
# and records only a LOCAL hash of that tree in .dist-hash, so there is nothing
# on the VM to compare a registry digest against. Closing that needs the deploy
# to record the configs-image digest it extracted; see rep-P.md §6. The #114
# dagu case was of this kind. The #354 mechanism — build succeeds, deploy is
# evicted — produces image drift whenever the service's code changed at all,
# which is the case the live casualty and the majority of ships fall into.
#
# CONTRACT
#
#   argv      : zero or more VM aliases; default = every VM in build-gha.json
#   stdout    : one TSV line per finding — <vm> <service_dir> <class> <detail>
#               class `drift`  = running digest != registry digest → RE-SHIP
#               class `absent` = declared, no running container    → REPORT ONLY
#   stderr    : the reasoning, one line per service
#   exit 0    : every declared service reconciles
#   exit 1    : at least one `drift` finding (re-shippable)
#   exit 2    : the reconcile itself could not run (config/probe failure)
#
# `absent` is deliberately NOT re-shipped. Nine services read absent on the
# fleet today (alerts-api, gha-runner, backup-bup, postlite, redis,
# wireguard-mesh, openobserve, matrix-mautrix-whatsapp, photoprism,
# playlist-syncer) for reasons that are not #354 — retired, on-demand, or run
# outside compose. Auto-shipping them would hold the WG runner for an hour to
# fix nothing, which is the #179 failure mode wearing a different hat.
#
# TESTING SEAMS
#
# The two impure operations are injectable so the tester needs neither a fleet
# nor a network. Both default to the real implementation:
#   RECONCILE_PROBE_CMD     <vm> <container>...  -> TSV container/ref/digest
#   RECONCILE_REGISTRY_CMD  <image_ref>          -> one sha256:... per line
# 9_others/test/test_ship_reconcile.sh drives both.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CLOUD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Where the container repository is checked out. It is a sibling repository
# (diegonmarcos/cloud-u-containers) that both CI and the shared tree place at
# a_solutions/, which is where every in-repo reference already looks.
SOLUTIONS_DIR="${SOLUTIONS_DIR:-$REPO_ROOT/a_solutions}"

# Registry we publish to. Anything a container runs from OUTSIDE this registry
# is upstream (postgres, redis, …): we do not build it, so its digest moving is
# not our drift and pinning it is not our decision.
OUR_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}"

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

# ── Service declarations ──────────────────────────────────────────────────
# Same resolution ladder ship.yml's detect and cloud-ship-ci-builder-dispatch.sh
# use. GHA_CONFIG may be preset (the tester does this) to bypass the search.
#
# The ladder is copy #5 of the same eight lines; the four existing copies live
# in cloud-ship-ci-builder-dispatch.sh, cloud-ship-orchestrate-ghcr.sh,
# cloud-ship-orchestrate-portable.sh and ship.yml itself. Consolidating them is
# a change to three files other agents are editing right now, so it is recorded
# as debt in rep-P.md §7 rather than done here.
if [ -z "${GHA_CONFIG:-}" ]; then
  for _p in \
      "/app/build-gha.json" \
      "$REPO_ROOT/1_cloud-configs/dist/build-gha.json" \
      "$REPO_ROOT/cloud-data/build-gha.json" \
      "$REPO_ROOT/build-gha.json"; do
    [ -f "$_p" ] && { GHA_CONFIG="$_p"; break; }
  done
fi
[ -n "${GHA_CONFIG:-}" ] && [ -f "$GHA_CONFIG" ] \
  || die "build-gha.json not found — run 9_others/build.sh, or set GHA_CONFIG"

command -v jq >/dev/null 2>&1 || die "jq is required"

# ── Seam 1: observe one VM ────────────────────────────────────────────────
# Prints TSV: <container> <config_image_ref> <running_repo_digest>
#
# Two round-trips, because the two facts live on two different Docker objects
# and conflating them is a real bug in the tree: step_status reads
# `.[0].RepoDigests[0]` from a CONTAINER inspect, where that key does not
# exist. Verified on oci-apps:
#   template parsing error: ... at <.RepoDigests>: map has no entry for key
# The container carries `.Image` (an image id) and `.Config.Image` (the ref);
# `RepoDigests` is a property of the IMAGE.
#
# Both commands are brace-free on the wire. oci-apps' login shell is fish, and
# Go `--format` templates do not survive the sh -> ssh -> fish quoting layers,
# so the JSON is fetched raw and parsed here with jq.
probe_vm_real() {
  _vm="$1"; shift
  [ "$#" -gt 0 ] || return 0

  _cjson="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$_vm" \
              "docker inspect $*" 2>/dev/null || true)"
  printf '%s' "$_cjson" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0

  # image id -> ref, for the containers that are actually up
  _pairs="$(printf '%s' "$_cjson" \
            | jq -r '.[] | select(.Name != null)
                     | "\(.Name | ltrimstr("/"))\t\(.Image)\t\(.Config.Image // "")"')"
  [ -n "$_pairs" ] || return 0

  _ids="$(printf '%s\n' "$_pairs" | cut -f2 | sort -u | tr '\n' ' ')"
  _ijson="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$_vm" \
              "docker image inspect $_ids" 2>/dev/null || true)"

  # id -> first RepoDigest. An image built on the VM and never pushed has an
  # empty RepoDigests array; it gets an empty digest here and is classified
  # `unpublished` by the caller rather than silently called in-sync.
  _digests="$(printf '%s' "$_ijson" \
              | jq -r '(.[]? | "\(.Id)\t\(.RepoDigests[0] // "")")' 2>/dev/null || true)"

  printf '%s\n' "$_pairs" | while IFS="$(printf '\t')" read -r _c _id _ref; do
    _d="$(printf '%s\n' "$_digests" | awk -F'\t' -v id="$_id" '$1==id {print $2; exit}')"
    printf '%s\t%s\t%s\n' "$_c" "$_ref" "${_d##*@}"
  done
}

# ── Seam 2: ask the registry what the current digest is ───────────────────
# Prints every digest that legitimately identifies <ref> right now: the index
# digest AND each per-arch child manifest digest.
#
# Both are needed. `:latest` may be a multi-arch index, and depending on how
# the VM pulled, the container's RepoDigest records EITHER the index digest OR
# the per-arch manifest digest. Comparing against the index alone reports a
# correct arm64 deploy as drift (PLAN-engine-verbs.md §5).
registry_digests_real() {
  _ref="$1"
  _path="${_ref#*/}"            # ghcr.io/owner/name:tag -> owner/name:tag
  _tag="${_path##*:}"
  _repo="${_path%:*}"
  [ "$_tag" = "$_path" ] && _tag="latest"

  # Anonymous pull token for public packages; the PAT upgrades it for private
  # ones. GH_TOKEN is never echoed — it is passed to curl and discarded.
  if [ -n "${GH_TOKEN:-}" ]; then
    _tok="$(curl -sS -u "x:$GH_TOKEN" \
              "https://ghcr.io/token?scope=repository:$_repo:pull&service=ghcr.io" \
            | jq -r '.token // empty' 2>/dev/null || true)"
  else
    _tok="$(curl -sS \
              "https://ghcr.io/token?scope=repository:$_repo:pull&service=ghcr.io" \
            | jq -r '.token // empty' 2>/dev/null || true)"
  fi
  [ -n "$_tok" ] || return 0

  _accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  _url="https://ghcr.io/v2/$_repo/manifests/$_tag"

  # The index/manifest digest the registry itself reports for the tag.
  curl -sSI -H "Authorization: Bearer $_tok" -H "Accept: $_accept" "$_url" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}'

  # Plus every child manifest, when the tag resolves to an index.
  curl -sS -H "Authorization: Bearer $_tok" -H "Accept: $_accept" "$_url" \
    | jq -r '(.manifests // [])[].digest' 2>/dev/null || true
}

PROBE_CMD="${RECONCILE_PROBE_CMD:-}"
REGISTRY_CMD="${RECONCILE_REGISTRY_CMD:-}"
probe_vm()         { if [ -n "$PROBE_CMD" ];    then $PROBE_CMD "$@"; else probe_vm_real "$@"; fi; }
registry_digests() { if [ -n "$REGISTRY_CMD" ]; then $REGISTRY_CMD "$@"; else registry_digests_real "$@"; fi; }

# ── Which VMs ─────────────────────────────────────────────────────────────
if [ "$#" -gt 0 ]; then
  VMS="$*"
else
  # Only VMs that actually host a declared service. Driven from the
  # declarations, never from a list in this file.
  VMS="$(jq -r '[.services[].vm] | unique[]' "$GHA_CONFIG" | tr '\n' ' ')"
fi
[ -n "${VMS// /}" ] || die "no VMs to reconcile"

RC=0
FOUND_ANY_CONTAINER=0

for vm in $VMS; do
  # service dir -> container names, straight from each service's own build.json.
  # A service with no containers[] block (pure config, wrangler-only, …) has
  # nothing running to compare and is skipped rather than guessed at.
  MAP="$(mktemp)"; trap 'rm -f "$MAP"' EXIT
  : > "$MAP"

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    bj="$SOLUTIONS_DIR/$dir/build.json"
    [ -f "$bj" ] || { note "  $dir: no build.json at $bj — skipped"; continue; }
    jq -r '(.containers // [])[] | .container_name // empty' "$bj" 2>/dev/null \
      | while IFS= read -r cn; do
          [ -n "$cn" ] && printf '%s\t%s\n' "$cn" "$dir" >> "$MAP"
        done
  done < <(jq -r --arg vm "$vm" '.services | to_entries[]
                                 | select(.value.vm == $vm)
                                 | .value.dir' "$GHA_CONFIG")

  CONTAINERS="$(cut -f1 "$MAP" | sort -u | tr '\n' ' ')"
  if [ -z "${CONTAINERS// /}" ]; then
    note "── $vm: no declared containers — nothing to reconcile"
    continue
  fi

  note "── $vm: probing $(printf '%s' "$CONTAINERS" | wc -w) declared container(s)"
  OBSERVED="$(probe_vm "$vm" $CONTAINERS || true)"

  # A VM that answers nothing is a BROKEN PROBE, not a clean fleet. Reporting
  # "all in sync" because the ssh failed is the same false-green this whole
  # script exists to delete.
  if [ -z "$OBSERVED" ]; then
    note "::error::$vm: probe returned nothing — cannot assert this VM is in sync"
    RC=2
    continue
  fi
  FOUND_ANY_CONTAINER=1

  # Cache registry lookups per ref: several containers legitimately share one
  # image (cloud-cgc-pub-mcp and cloud-cgc-pvt-mcp both run
  # cloud-cgc-pub-mcp-binaries:latest), and one HTTP round-trip each is enough.
  DESIRED_CACHE="$(mktemp)"; : > "$DESIRED_CACHE"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cname="$(printf '%s' "$line" | cut -f1)"
    ref="$(printf '%s' "$line" | cut -f2)"
    running="$(printf '%s' "$line" | cut -f3)"
    dir="$(awk -F'\t' -v c="$cname" '$1==c {print $2; exit}' "$MAP")"
    [ -n "$dir" ] || continue

    case "$ref" in
      "$OUR_REGISTRY"/*) ;;
      *) note "  $dir/$cname: $ref is upstream — not ours to reconcile"; continue ;;
    esac

    if [ -z "$running" ]; then
      note "  $dir/$cname: running an image with no RepoDigest — built on the VM, never published"
      printf '%s\t%s\t%s\t%s\n' "$vm" "$dir" "unpublished" "$cname"
      continue
    fi

    desired="$(awk -F'\t' -v r="$ref" '$1==r {print $2; exit}' "$DESIRED_CACHE")"
    if [ -z "$desired" ]; then
      desired="$(registry_digests "$ref" | grep '^sha256:' | sort -u | tr '\n' ',' || true)"
      printf '%s\t%s\n' "$ref" "${desired:-NONE}" >> "$DESIRED_CACHE"
    fi
    [ "$desired" = "NONE" ] && desired=""

    if [ -z "$desired" ]; then
      note "  $dir/$cname: registry did not answer for $ref — undecidable, NOT called in-sync"
      RC=2
      continue
    fi

    if printf '%s' ",$desired," | grep -qF ",$running,"; then
      note "  $dir/$cname: in-sync ($running)"
    else
      note "  $dir/$cname: DRIFT — running ${running}, registry has ${desired%%,*}"
      printf '%s\t%s\t%s\t%s\n' "$vm" "$dir" "drift" "$cname running=$running registry=${desired%%,*}"
      [ "$RC" -eq 2 ] || RC=1
    fi
  done <<< "$OBSERVED"

  # Declared containers the probe never mentioned are not running at all.
  while IFS="$(printf '\t')" read -r cname dir; do
    [ -n "$cname" ] || continue
    printf '%s' "$OBSERVED" | cut -f1 | grep -qxF "$cname" && continue
    note "  $dir/$cname: ABSENT — declared but not running (reported, not re-shipped)"
    printf '%s\t%s\t%s\t%s\n' "$vm" "$dir" "absent" "$cname"
  done < "$MAP"

  rm -f "$DESIRED_CACHE" "$MAP"
done

if [ "$RC" -eq 0 ] && [ "$FOUND_ANY_CONTAINER" -eq 0 ]; then
  note "::error::reconcile observed zero containers fleet-wide — that is a broken probe, not a clean fleet"
  exit 2
fi

case "$RC" in
  0) note "RECONCILED — every declared container runs the digest the registry holds" ;;
  1) note "DRIFT — the services listed on stdout are committed, built, and NOT on the fleet" ;;
  2) note "UNDECIDABLE — at least one VM or image could not be read; no in-sync claim is made for it" ;;
esac
exit "$RC"
