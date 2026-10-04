#!/usr/bin/env bash
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
for fn in lance_newest_manifest lance_prune_old_versions lance_dangling_tables; do
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

# Wired in: publish gate, checkpoint restore, and restore-all staging.
grep -q 'lance_prune_old_versions "\$OCTO_HOME"' "$UPD" && ok "update.sh prunes OCTO_HOME" || bad "update.sh never prunes"
grep -q 'lance_prune_old_versions "\$STAGING"' "$RST" && ok "restore-all prunes STAGING" || bad "restore-all never prunes"
grep -q 'sort | head -1)' "$UPD" "$RST" && bad "a sort|head newest-manifest pick is back" || ok "no sort|head manifest pick left"

echo "PASS=$pass FAIL=$fail"; [ "$fail" = 0 ]
