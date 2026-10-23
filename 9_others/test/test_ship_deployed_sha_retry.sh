#!/usr/bin/env bash
# A failed deploy must be retried on the next run. Change detection used to diff
# only the last commit, so once a deploy failed the next run said "SKIP caddy
# (unchanged)" for ever. The per-VM/per-service deployed-sha marker
# (cloud-ship-deployed-sha.sh, written by the dispatcher after a green deploy)
# makes detection compare against the last SUCCESSFULLY deployed commit.
# Usage: bash 9_others/test/test_ship_deployed_sha_retry.sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/1_cicd/src/scripts/cloud-ship-deployed-sha.sh"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
g() { git -C "$T" -c user.email=t@t -c user.name=t "$@"; }
g init -q; mkdir -p "$T/caddy/src" "$T/other/src"
echo 1 > "$T/caddy/src/a"; echo 1 > "$T/other/src/a"; g add -A; g commit -qm c1; C1=$(g rev-parse HEAD)
echo 2 > "$T/caddy/src/a"; g commit -qam c2-caddy   # the deploy of this one "failed"
echo 2 > "$T/other/src/a"; g commit -qam c3-other; C3=$(g rev-parse HEAD)

r() { bash "$H" retry "$T" "$@" >/dev/null 2>&1 && echo retry || echo skip; }
ck "failed deploy (marker=c1, caddy changed in c2) is retried at c3" "$(r caddy "$C1" "$C3")" retry
ck "service deployed at head is skipped" "$(r caddy "$C3" "$C3")" skip
ck "other changed in c3 after marker=c2 is retried" "$(r other "$(g rev-parse HEAD~1)" "$C3")" retry
ck "no marker never mass-deploys on rollout" "$(r caddy "" "$C3")" skip
ck "unknown marker sha is skipped" "$(r caddy deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$C3")" skip
ck "caddy untouched between c2 and c3 is skipped" "$(r caddy "$(g rev-parse HEAD~1)" "$C3")" skip
ck "lookup picks the service's marker" "$(bash "$H" lookup "$(printf 'caddy:abc\nother:def')" other)" def

# Wiring: the dispatcher the workflows run must read and write the marker.
for d in 1_cicd/src/scripts 1_cicd/dist/scripts; do
  f="$ROOT/$d/cloud-ship-ci-builder-dispatch.sh"
  ck "$d: dispatcher reads markers and retries" "$(grep -c 'cloud-ship-deployed-sha\|_DS_HELPER" retry' "$f" | awk '{print ($1>=2)?"yes":"no"}')" yes
  ck "$d: marker is written only inside the OK branch" \
     "$(awk '/echo "OK \$name"/{o=1} o&&/\.ship-deployed/{print "yes"; exit} /FAIL \$name/{print "no"; exit}' "$f")" yes
done
echo "  passed $pass, failed $fail"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
