#!/usr/bin/env bash
# Deployed-sha marker helper for change detection.
#
# Ship decides what to deploy by diffing the push (or the last cloud-u-containers
# commit) against its base. A deploy that FAILED is therefore never retried: the
# next run's base has already moved past it ("SKIP caddy (unchanged)"). The fix
# is a per-VM, per-service marker of the last SUCCESSFULLY deployed a_solutions
# commit, kept on the VM at ~/.ship-deployed/<dir>, written only after a green
# deploy. A service the diff calls unchanged is still shipped when it differs
# from its marker.
#
#   retry <a_solutions-dir> <service-dir> <marker-sha> <head-sha>
#       exit 0 (prints "retry") if the service changed between marker and head.
#       exit 1 when there is no usable marker (never mass-deploy on rollout),
#       marker == head, or nothing under the service changed.
#   lookup <markers-text> <service-dir>
#       markers-text is "<dir>:<sha>" lines (one ssh round trip per VM).
set -u
case "${1:-}" in
  retry)
    as="${2:?}" dir="${3:?}" marker="${4:-}" head="${5:?}"
    [ -n "$marker" ] && [ "$marker" != "$head" ] || exit 1
    git -C "$as" cat-file -e "${marker}^{commit}" 2>/dev/null || exit 1
    git -C "$as" diff --name-only "$marker" "$head" -- "$dir/src" "$dir/dist" "$dir/build.json" 2>/dev/null | grep -q . || exit 1
    echo retry ;;
  lookup)
    printf '%s\n' "${2:-}" | awk -F: -v d="${3:?}" '$1==d {print $2; exit}' ;;
  *) echo "usage: $0 retry|lookup ..." >&2; exit 2 ;;
esac
