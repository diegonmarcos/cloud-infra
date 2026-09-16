#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-reconcile.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

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
#               class `undecidable` = registry would not answer    → REPORT ONLY
#               class `unpublished` = running an unpushed image    → REPORT ONLY
#               class `unreachable` = VM would not answer          → REPORT ONLY
#   stderr    : the reasoning, one line per service
#   exit 0    : every declared service reconciles
#   exit 1    : at least one `drift` finding (re-shippable)
#   exit 2    : the reconcile itself could not run (config, or a VM that would
#               not answer at all). NOT used for individual images that could
#               not be decided — two of the fleet's packages are private and
#               may never be readable from here, and a scheduled watchdog that
#               is permanently red is ignored exactly as fast as one that is
#               permanently green.
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

  # Retried, because the mesh drops connections and a read-only probe is the
  # safest thing in the engine to repeat. oci-mail answered normally in run
  # 35039429321 and timed out at exactly ConnectTimeout in 35039770510 fifteen
  # minutes later; one transient link fault made the whole fleet sweep
  # undecidable and the job red. The deploy path already treats ssh 255 as a
  # link fault rather than a code fault (SHIP_EXIT_TRANSPORT in
  # cloud-ship-container-step-deploy-rsync.sh); this is the read-only analogue.
  _cjson=""
  for _try in 1 2 3; do
    _cjson="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$_vm" \
                "docker inspect $*" 2>/dev/null || true)"
    printf '%s' "$_cjson" | jq -e 'type == "array"' >/dev/null 2>&1 && break
    _cjson=""
    [ "$_try" -lt 3 ] && { note "  $_vm: probe attempt $_try did not answer — retrying"; sleep 5; }
  done

  # UNREACHABLE is not the same fact as "nothing matched", and collapsing them
  # is how a silent failure gets built. A VM that answers with an empty array
  # has told us something true (none of the declared containers are running);
  # a VM that never answers has told us nothing, and nothing on it may be
  # called in-sync. The caller needs to tell those apart, so the unreachable
  # case is stated on the wire rather than inferred from empty output.
  if [ -z "$_cjson" ]; then
    printf '#UNREACHABLE\n'
    return 0
  fi

  # image id -> ref, for the containers that are actually up
  _pairs="$(printf '%s' "$_cjson" \
            | jq -r '.[] | select(.Name != null)
                     | "\(.Name | ltrimstr("/"))\t\(.Image)\t\(.Config.Image // "")"')"
  # Reachable but nothing declared is running: return cleanly with no rows, so
  # every declared container falls through to `absent` below.
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
#
# #358: the credential moved, and the logic moved with it into
# cloud-ship-registry-digest.sh so that `status` answers this question the same
# way instead of a second time. The old ladder here was
# CGC_GHCR_PAT -> GH_TOKEN -> anonymous, and it never once read a private
# package, for the plain reason that ship-reconcile.yml does not set
# CGC_GHCR_PAT in this job — it only sets GH_TOKEN (see its `Reconcile` step).
# So the PAT branch was dead code that nonetheless documented reaching for a
# classic admin token, and the live effect was three fleet packages
# permanently `undecidable`. It is not reinstated: #359 removed that same
# credential from this workflow's dispatch step because it carries
# delete_repo. The VM's own pull credential answers the question instead, on
# the VM, and is the narrowest thing that can. The VM alias is now passed in
# for exactly that reason.
registry_digests_real() {
  bash "$SCRIPT_DIR/cloud-ship-registry-digest.sh" "$1" "${2:-}"
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
FOUND_ANY_VM=0

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

    # `map(select(type == "object"))` is not defensive padding, it is required:
    # containers[] is NOT homogeneous across the fleet. infra-db_postlite's
    # array mixes objects with a bare string, and `.container_name` on a string
    # is a jq RUNTIME error — jq prints three container names, then exits 5.
    # Under `set -o pipefail` that killed the whole reconcile at the second VM,
    # and the `2>/dev/null` this line used to carry meant it died having printed
    # nothing at all. Run 35038684236 failed exactly that way: 0.03s, no output,
    # exit 5. A reconcile whose job is to delete silent failures must not have
    # one of its own.
    #
    # Errors are captured and reported rather than discarded, and one unreadable
    # service is skipped rather than being allowed to abort the fleet sweep —
    # losing 67 services' worth of answer to one malformed declaration is a far
    # worse outcome than the malformed declaration itself.
    _names=""; _jqerr=""
    if _names="$(jq -r '(.containers // [])
                        | map(select(type == "object"))
                        | .[] | .container_name // empty' "$bj" 2>/tmp/reconcile-jq-err)"; then
      :
    else
      _jqerr="$(cat /tmp/reconcile-jq-err 2>/dev/null || true)"
      note "  $dir: build.json unreadable — skipped. jq said: ${_jqerr:-<no message>}"
      continue
    fi
    [ -n "$_names" ] || { note "  $dir: no containers[].container_name — nothing running to compare"; continue; }
    printf '%s\n' "$_names" | while IFS= read -r cn; do
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

  # A VM that will not answer is a BROKEN PROBE, not a clean fleet. Reporting
  # "all in sync" because the ssh failed is the same false-green this whole
  # script exists to delete, so this stays fatal.
  if printf '%s\n' "$OBSERVED" | grep -qx '#UNREACHABLE'; then
    # Reported loudly and recorded as a finding, but it does NOT stop the run.
    # One VM behind a transient mesh fault used to make the whole sweep exit 2,
    # which blocked the re-ship of drift already found on the three VMs that
    # answered perfectly well — #354 continuing quietly because of a dropped
    # packet. Nothing on THIS VM is called in-sync; everything known about the
    # others still gets acted on.
    note "::error::$vm: did not answer after 3 attempts — nothing on this VM is being called in-sync"
    printf '%s\t%s\t%s\t%s\n' "$vm" "-" "unreachable" "probe failed after 3 attempts"
    continue
  fi
  FOUND_ANY_VM=1

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

    # A DIGEST-PINNED ref answers itself. This is resolved HERE rather than
    # inside registry_digests_real because it is pure ref parsing, not a
    # registry operation — putting it behind the seam meant the tester, which
    # replaces that whole function, could never reach it.
    #
    # gcp-proxy's caddy runs ghcr.io/diegonmarcos/caddy-l4@sha256:d8309fad…, and
    # splitting that on the last ':' gave repo "…/caddy-l4@sha256" and tag
    # "d8309fad…", which the registry refused — the most decidable image on the
    # fleet reported as undecidable. A pin cannot drift from the registry: it
    # names its own digest. It CAN drift from what is actually running, and that
    # comparison still happens below, which is the case worth catching.
    case "$ref" in
      *@sha256:*)
        desired="sha256:${ref##*@sha256:}"
        ;;
      *)
        desired="$(awk -F'\t' -v r="$ref" '$1==r {print $2; exit}' "$DESIRED_CACHE")"
        if [ -z "$desired" ]; then
          desired="$(registry_digests "$ref" "$vm" | grep '^sha256:' | sort -u | tr '\n' ',' || true)"
          printf '%s\t%s\n' "$ref" "${desired:-NONE}" >> "$DESIRED_CACHE"
        fi
        ;;
    esac
    [ "$desired" = "NONE" ] && desired=""

    if [ -z "$desired" ]; then
      # Reported as a finding, NOT counted as in-sync, and NOT fatal.
      #
      # Fatal was wrong. Two of the fleet's images are private packages this
      # job may never hold a credential for, so exit 2 made the scheduled
      # reconcile permanently red — and a watchdog that is always red is
      # ignored exactly as fast as one that is always green, which is the
      # pathology this whole ticket is about. What genuinely warrants exit 2 is
      # "the reconcile could not run" (a VM that would not answer at all),
      # not "two images out of sixty could not be decided". Those are surfaced
      # on stdout as their own class so the run summary names them and the
      # re-ship step ignores them.
      note "  $dir/$cname: registry did not answer for $ref — undecidable, NOT called in-sync"
      printf '%s\t%s\t%s\t%s\n' "$vm" "$dir" "undecidable" "$cname ref=$ref"
      continue
    fi

    if printf '%s' ",$desired," | grep -qF ",$running,"; then
      note "  $dir/$cname: in-sync ($running)"
    else
      note "  $dir/$cname: DRIFT — running ${running}, registry has ${desired%%,*}"
      printf '%s\t%s\t%s\t%s\n' "$vm" "$dir" "drift" "$cname running=$running registry=${desired%%,*}"
      RC=1
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

# Not "zero containers" — zero VMS. A VM legitimately running none of its
# declared containers is a real answer (they come out as `absent` findings);
# no VM answering at all means the reconcile never ran.
if [ "$FOUND_ANY_VM" -eq 0 ]; then
  note "::error::no VM answered the probe — the reconcile did not run, and a clean fleet is NOT what this means"
  exit 2
fi

case "$RC" in
  0) note "RECONCILED — every declared container runs the digest the registry holds" ;;
  1) note "DRIFT — the services listed on stdout are committed, built, and NOT on the fleet" ;;
  2) note "UNDECIDABLE — the reconcile could not run at all" ;;
esac
exit "$RC"
