#!/usr/bin/env bash
# #888: a forced run must look for its saved partial under the SAME phase tag that
# publish writes. MANIFEST_PHASE has to be set before the first resume_force_partial
# call, i.e. before any line that uses it.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
assign=$(grep -n '^MANIFEST_PHASE="\${CGC_MANIFEST_PHASE:-}"' "$UPD" | head -1 | cut -d: -f1)
first_call=$(grep -n '^[[:space:]]*resume_force_partial "' "$UPD" | head -1 | cut -d: -f1)
[ -n "$assign" ] && [ -n "$first_call" ] || { echo "FAIL: assignment or resume call not found"; exit 1; }
[ "$assign" -lt "$first_call" ] || { echo "FAIL: MANIFEST_PHASE assigned at line $assign, after first resume at line $first_call"; exit 1; }
# The tag function must yield the graphrag tag when the phase is graphrag.
fn=$(grep '^force_partial_tag()' "$UPD")
out=$(REPO_TAG=latest CGC_MANIFEST_PHASE=graphrag bash -c "MANIFEST_PHASE=\"\${CGC_MANIFEST_PHASE:-}\"; $fn; force_partial_tag")
[ "$out" = "latest-force-graphrag" ] || { echo "FAIL: tag is '$out'"; exit 1; }
echo "ok: phase set at line $assign < first resume at line $first_call; tag=$out"
echo PASS
