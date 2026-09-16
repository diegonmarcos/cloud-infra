#!/bin/sh
# The container nix engine must stamp the SAME generated-file marker as the
# cloud-infra shell engine.
#
# The bug (found 2026-09-16, ticket #372, from X2-F12): two engines stamp
# a_solutions/*/dist/, and each carried its own idea of the banner.
#   - cloud-infra's inject-header.sh reads the marker from
#     9_others/src/generated-header.json  ("GENERATED FILE — DO NOT EDIT")
#   - cloud-u-containers' _shared/engine.nix HARDCODED a different wording
#     ("DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY")
# 255 container dist/ files carry the nix engine's wording. They are stamped
# artifacts, but test_service_header_present.sh — which only knows the JSON
# marker — reads every one of them as unstamped the moment it is in scope.
# That surfaced as "a service lost its banner" when the truth was that the
# marker is DATA in one engine and a string literal in the other.
#
# This is the recurring shape: a hardcoded value that must agree with a JSON
# source of truth, with nothing checking the agreement. This is that check.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
HEADER_JSON="$REPO_ROOT/9_others/src/generated-header.json"
ENGINE_NIX="$REPO_ROOT/a_solutions/_shared/engine.nix"

fail=0

# A check that cannot reach its subject FAILS. a_solutions is a separate
# repository (diegonmarcos/cloud-u-containers) that CI checks out into this
# path; if the checkout is missing, this tester has verified NOTHING and must
# say so rather than exiting 0 over an absent file.
if [ ! -f "$ENGINE_NIX" ]; then
  echo "::error::$ENGINE_NIX not found — the cloud-u-containers checkout is missing, so the container engine's marker was NOT verified."
  exit 1
fi

MARKER="$(jq -r '.marker' "$HEADER_JSON")"
[ -n "$MARKER" ] && [ "$MARKER" != "null" ] || {
  echo "::error::generated-header.json has no .marker — nothing to compare against"; exit 1; }

echo "── canonical marker: $MARKER ──"

if grep -qF "$MARKER" "$ENGINE_NIX"; then
  echo "  ok   _shared/engine.nix stamps the canonical marker"
else
  echo "  FAIL _shared/engine.nix does not contain the canonical marker '$MARKER'."
  echo "       Its banner is what every a_solutions/*/dist/ file built by nix carries,"
  echo "       and test_service_header_present.sh will read all of them as unstamped."
  fail=$((fail+1))
fi

if [ "$fail" -eq 0 ]; then
  echo "--- container engine marker agrees with generated-header.json"
  exit 0
fi
echo "::error::$fail marker mismatch(es) between the two generated-file engines"
exit 1
