#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-lance-prune.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# lance_newest_manifest() / lance_prune_old_versions() (cloud-cgc-db-update.sh, copied
# verbatim into cloud-cgc-db-restore-all.sh). Run 37146011415's restore-all died with
# "no space left on device": octocode never drops old lance versions, and
# cloud-u-containers' file_metadata.lance held 3.0G of manifests against 35M of data.
# Pins: (1) newest manifest is picked right for BOTH lance naming schemes and on
# ~10k-entry dirs; (2) pruning keeps the newest N, never touches data/ or non-numeric
# names, and leaves a table the integrity check still reads as healthy;
# (3) both script copies are byte-identical. Functions are extracted BY NAME.
set -uo pipefail
ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
RST="$ROOT/1_cicd/src/ops/cloud-cgc-db-restore-all.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
ext() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^\}$/{exit}' "$2"; }
for fn in lance_newest_manifest lance_prune_old_versions lance_gc_unreferenced_data lance_dangling_tables; do
  a="$(ext $fn "$UPD")"; b="$(ext $fn "$RST")"
  [ -n "$a" ] || { echo "::error::cannot extract $fn from $UPD"; exit 1; }
  [ "$a" = "$b" ] && ok "$fn identical in update.sh and restore-all.sh" || bad "$fn drifted between update.sh and restore-all.sh"
  eval "$a"
done

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
F=00111111010110100011100111cda449a497482bee18280916.lance
mkman() { printf 'LANC\070%s\000\001' "$F" > "$1"; }

# V2 naming, 10000 versions: newest = smallest name (u64::MAX - version).
T="$W/h/p1/storage/file_metadata.lance"; mkdir -p "$T/_versions" "$T/data" "$T/_transactions"
for v in $(seq 1 10000); do : > "$T/_versions/$(echo "18446744073709551615 - $v" | bc).manifest"; done
mkman "$T/_versions/18446744073709541615.manifest"   # v10000, the newest
printf 'DATA' > "$T/data/$F"; : > "$T/_transactions/x.txn"
got=$(lance_newest_manifest "$T" 2>&1)
[ "$got" = 18446744073709541615.manifest ] && ok "V2 newest over 10000 manifests, no SIGPIPE noise" || bad "V2 newest: got '$got'"

# V1 naming: newest = largest number, NOT lexicographically first.
T1="$W/h/p1/storage/code_blocks.lance"; mkdir -p "$T1/_versions" "$T1/data"
for v in 1 2 9 10 11; do : > "$T1/_versions/$v.manifest"; done
mkman "$T1/_versions/11.manifest"; : > "$T1/_versions/_latest.manifest"; printf 'DATA' > "$T1/data/$F"
got=$(lance_newest_manifest "$T1"); [ "$got" = 11.manifest ] && ok "V1 newest = 11, not '1'" || bad "V1 newest: got '$got'"

lance_prune_old_versions "$W/h" 2 >/dev/null
n=$(ls "$T/_versions" | wc -l)
[ "$n" = 2 ] && ok "V2 pruned to 2 manifests" || bad "V2 kept $n"
[ -e "$T/_versions/18446744073709541615.manifest" ] && [ -e "$T/_versions/18446744073709541616.manifest" ] && ok "V2 kept the two newest" || bad "V2 dropped a newest manifest"
[ -e "$T/data/$F" ] && [ -e "$T/_transactions/x.txn" ] && ok "data/ and _transactions/ untouched" || bad "prune touched data"
[ "$(ls "$T1/_versions" | tr '\n' ' ')" = "10.manifest 11.manifest _latest.manifest " ] && ok "V1 kept 10,11 and _latest" || bad "V1 left: $(ls "$T1/_versions" | tr '\n' ' ')"
[ -z "$(lance_dangling_tables "$W/h")" ] && ok "pruned home still passes the integrity check" || bad "prune tore a table"
mkdir -p "$W/h/fastembed"; lance_prune_old_versions "$W/h" >/dev/null && ok "no-op second pass exits 0" || bad "second pass failed"

# lance_gc_unreferenced_data (#988): drops data fragments no kept manifest names,
# keeps every one that a kept manifest names -- including a reference followed by a
# hex-looking protobuf byte, which the gate's $-anchored grep would not see -- and
# fails closed on a table whose references do not parse or do not match data/.
G="$W/g"; F2=11000101011010001111111110a1b2c3d4e5f60718293a4b5c.lance
T2="$G/p2/storage/code_blocks.lance"; mkdir -p "$T2/_versions" "$T2/data"
printf 'LANC\070%s\000\001' "$F" > "$T2/_versions/18446744073709551000.manifest"
printf 'LANC\070%s0\001' "$F2" > "$T2/_versions/18446744073709551001.manifest"
printf 'DATA' > "$T2/data/$F"; printf 'DATA' > "$T2/data/$F2"
for g in 0101010101010101010101010101010101010101010101aaaa 0202020202020202020202020202020202020202020202bbbb; do printf 'OLD' > "$T2/data/$g.lance"; done
T3="$G/p2/storage/text_blocks.lance"; mkdir -p "$T3/_versions" "$T3/data"   # no parsable reference
printf 'LANC\000\001' > "$T3/_versions/1.manifest"; printf 'DATA' > "$T3/data/$F"
T4="$G/p2/storage/commit_blocks.lance"; mkdir -p "$T4/_versions" "$T4/data"  # references match nothing on disk
printf 'LANC\070%s\000' "$F2" > "$T4/_versions/1.manifest"; printf 'DATA' > "$T4/data/$F"
mkdir -p "$G/fastembed"
out=$(lance_gc_unreferenced_data "$G")
[ -e "$T2/data/$F" ] && [ -e "$T2/data/$F2" ] && ok "gc kept both referenced fragments (one only an older kept manifest names, one followed by a hex byte)" || bad "gc deleted a referenced fragment"
[ "$(ls "$T2/data" | wc -l)" = 2 ] && ok "gc removed the 2 unreferenced fragments" || bad "gc left: $(ls "$T2/data" | tr '\n' ' ')"
[ -e "$T3/data/$F" ] && ok "gc left a table with no parsable reference alone" || bad "gc emptied an unparsable table"
[ -e "$T4/data/$F" ] && ok "gc left a table whose references match nothing alone" || bad "gc emptied a table on a suspect parse"
case "$out" in *"removed 2 unreferenced"*) ok "gc reports what it removed" ;; *) bad "gc report: '$out'" ;; esac
[ -z "$(lance_dangling_tables "$G" | grep -v "$T4")" ] && ok "gc'd home still passes the integrity check" || bad "gc tore a table"
lance_gc_unreferenced_data "$G" >/dev/null && [ "$(ls "$T2/data" | wc -l)" = 2 ] && ok "gc second pass is a no-op" || bad "gc second pass changed data"

# Wired in: publish gate, checkpoint restore, and restore-all staging.
grep -q 'lance_prune_old_versions "\$OCTO_HOME"' "$UPD" && ok "update.sh prunes OCTO_HOME" || bad "update.sh never prunes"
grep -q 'lance_prune_old_versions "\$STAGING"' "$RST" && ok "restore-all prunes STAGING" || bad "restore-all never prunes"
[ "$(grep -c 'lance_gc_unreferenced_data "\$OCTO_HOME"' "$UPD")" = 2 ] && ok "update.sh gcs OCTO_HOME at both prune sites" || bad "update.sh gc not wired"
[ "$(grep -c 'lance_gc_unreferenced_data "\$STAGING"' "$RST")" = 2 ] && ok "restore-all gcs STAGING after base and every repo" || bad "restore-all gc not wired"
grep -q 'docker rmi "\$CURRENT_IMG"' "$RST" && ok "restore-all's EXIT trap drops a half-staged transport image" || bad "a failed stage still leaves its image behind"
grep -q 'sort | head -1)' "$UPD" "$RST" && bad "a sort|head newest-manifest pick is back" || ok "no sort|head manifest pick left"

echo "PASS=$pass FAIL=$fail"; [ "$fail" = 0 ]
