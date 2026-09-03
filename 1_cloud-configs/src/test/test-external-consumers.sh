#!/usr/bin/env bash
# test-external-consumers.sh — verify the external-consumers contract.
#
# 1_cloud-configs/src/inputs/external-consumers.json is the declarative registry of
# non-container consumers. 1_cloud-configs/src/derive/cloud-data-config-derive.ts
# (deriveExternalConsumers + getDeep helpers) emits one
# 1_cloud-configs/dist/build-{name}.json per registry entry, sliced from
# _cloud-data-consolidated.json.
#
# Asserted invariants:
#   1. Registry parses + every entry has {name, consumer_path, slices[]}
#      with at least one slice declaration.
#   2. Engine emits one build-{name}.json for every registry entry.
#   3. Every declared slice key shows up in its emitted file with the
#      correct shape (object, non-empty when the consolidated source has
#      data).
#   4. The 'secrets' consumer's special filter (map_to_env_vars) produces
#      a {<svc>: [<env-var-names>]} map keyed by service.
#   5. Each consumer's actual read path resolves to a valid file given
#      a fresh dist/ — i.e. the priority chain in the consumer code
#      (node-npm-deps-cloud.nix, gen-claude-md.sh, ship-services.sh,
#      secrets.sh) lands on a real file with the expected slice.
#
# This test is registered by 9_others/build.sh `run_tests` (which iterates
# test-*.sh). No imperative arg-passing — fixture is the live engine output.

set -euo pipefail

# DERIVED FROM THIS FILE, not from a repo name. It was hardcoded to
# "$HOME/git/cloud" — the name this repo had before the 2026-08 rename to
# cloud-infra — so the first check failed on a missing registry and the script
# exited before reaching anything it actually guards. It has been red for a
# stale reason ever since, which is indistinguishable from red for a real one:
# the gen-claude-md.sh checks below never ran, and the directory they point at
# has since disappeared entirely without anyone hearing about it.
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "${GIT_BASE:-$HOME/git}/cloud-infra")"
DIST="$REPO/1_cloud-configs/dist"
REGISTRY="$REPO/1_cloud-configs/src/inputs/external-consumers.json"
CONSOLIDATED="$DIST/_cloud-data-consolidated.json"
FAILS=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILS=$((FAILS + 1)); }

echo "── 1. registry parses ──"
if [ -f "$REGISTRY" ]; then
    pass "$REGISTRY exists"
else
    fail "$REGISTRY missing"
    echo "test-external-consumers: FAIL"
    exit 1
fi

if jq -e '.consumers | type == "array" and length > 0' "$REGISTRY" >/dev/null; then
    pass "registry has non-empty consumers[] array"
else
    fail "registry consumers[] is missing or empty"
fi

# Validate every entry shape.
shape_bad=$(jq -r '
    .consumers[]
    | select((.name == null) or (.name == "")
          or (.consumer_path == null) or (.consumer_path == "")
          or (.slices | type != "array")
          or (.slices | length == 0))
    | .name // "<unnamed>"
' "$REGISTRY")
if [ -z "$shape_bad" ]; then
    pass "every consumer has {name, consumer_path, slices[]+}"
else
    fail "consumer entries missing required keys: $shape_bad"
fi

# Every slice entry must have {key, from}.
slice_bad=$(jq -r '
    .consumers[] as $c
    | $c.slices[]
    | select((.key == null) or (.key == "") or (.from == null) or (.from == ""))
    | "\($c.name).\(.key // "<no-key>")"
' "$REGISTRY")
if [ -z "$slice_bad" ]; then
    pass "every slice declares {key, from}"
else
    fail "slices missing key/from: $slice_bad"
fi

echo ""
echo "── 2. engine emits one build-{name}.json per consumer ──"
if [ ! -f "$CONSOLIDATED" ]; then
    fail "$CONSOLIDATED missing — run bash 9_others/build.sh all"
    echo "test-external-consumers: FAIL ($FAILS)"
    exit 1
fi

mapfile -t NAMES < <(jq -r '.consumers[].name' "$REGISTRY")
for name in "${NAMES[@]}"; do
    out="$DIST/build-${name}.json"
    if [ -f "$out" ]; then
        pass "build-${name}.json emitted"
    else
        fail "build-${name}.json missing — engine did not emit"
    fi
done

echo ""
echo "── 3. every declared slice lands in the emitted file ──"
# For each (consumer, slice), check that the emitted file has the slice key
# at top level. Also check the `consumer` self-reference and `_meta` header.
while IFS=$'\t' read -r name slice_key from_path filter; do
    out="$DIST/build-${name}.json"
    [ -f "$out" ] || continue
    if jq -e --arg k "$slice_key" 'has($k)' "$out" >/dev/null; then
        # Confirm the slice has data (not null) when the source path also has data.
        src_has=$(jq --arg p "$from_path" '
            ($p | split(".")) as $keys
            | reduce $keys[] as $k (.; if . == null then null else .[$k] end)
            | if . == null then "no" else "yes" end
        ' "$CONSOLIDATED")
        out_has=$(jq --arg k "$slice_key" '.[$k] | if . == null then "no" else "yes" end' "$out")
        if [ "$src_has" = "yes" ] && [ "$out_has" = "no" ]; then
            fail "build-${name}.json has key '$slice_key' but value is null (source $from_path has data)"
        else
            pass "build-${name}.json.${slice_key} ← consolidated.${from_path}${filter:+ [filter=$filter]}"
        fi
    else
        fail "build-${name}.json missing slice key '$slice_key'"
    fi
done < <(jq -r '
    .consumers[] as $c
    | $c.slices[]
    | [$c.name, .key, .from, (.filter // "")] | @tsv
' "$REGISTRY")

echo ""
echo "── 4. secrets.map_to_env_vars filter produces {svc: [VAR…]} ──"
SECRETS="$DIST/build-secrets.json"
if [ -f "$SECRETS" ]; then
    if jq -e '.services_env_vars | type == "object"' "$SECRETS" >/dev/null; then
        pass "build-secrets.json.services_env_vars is an object"
    else
        fail "build-secrets.json.services_env_vars is not an object"
    fi
    # Every value must be an array of strings.
    bad=$(jq -r '
        .services_env_vars // {}
        | to_entries[]
        | select((.value | type) != "array"
              or any(.value[]; type != "string"))
        | .key
    ' "$SECRETS")
    if [ -z "$bad" ]; then
        pass "every services_env_vars value is an array of strings"
    else
        fail "non-string-array values for: $bad"
    fi
    # Spot-check: cypht is known to declare CYPHT_DB_PASSWORD.
    if jq -e '.services_env_vars.cypht | index("CYPHT_DB_PASSWORD")' "$SECRETS" >/dev/null 2>&1; then
        pass "services_env_vars.cypht includes CYPHT_DB_PASSWORD (known fixture)"
    else
        # Not fatal — cypht may have been renamed. Just warn.
        echo "  · note: cypht.CYPHT_DB_PASSWORD spot-check did not match (acceptable if fixture changed)"
    fi
else
    fail "build-secrets.json missing"
fi

echo ""
echo "── 5. each consumer's actual read path resolves to a real file ──"

# 5a. flakes_desktop / flakes_termux nix module — check that the priority
# chain in node-npm-deps-cloud.nix references at least one existing path
# and that the file at that path has the .deps.node.merged.dependencies
# shape the activation script expects.
for who in desktop termux; do
    NIX_FILE="$HOME/git/cloud-infra-desktop/ba_flakes_${who}/src/modules/node-npm-deps-cloud.nix"
    [ "$who" = "termux" ] && NIX_FILE="$HOME/git/cloud-infra-desktop/bb_flakes_${who}/src/modules/node-npm-deps-cloud.nix"
    if [ ! -f "$NIX_FILE" ]; then
        fail "$NIX_FILE missing"
        continue
    fi
    if ! grep -q "build-flakes_${who}.json" "$NIX_FILE"; then
        fail "$NIX_FILE does not reference build-flakes_${who}.json"
        continue
    fi
    pass "node-npm-deps-cloud.nix (${who}) references build-flakes_${who}.json"
    BUILD="$DIST/build-flakes_${who}.json"
    if jq -e '.deps.node.merged.dependencies | type == "object"' "$BUILD" >/dev/null 2>&1; then
        n=$(jq '.deps.node.merged.dependencies | length' "$BUILD")
        pass "build-flakes_${who}.json.deps.node.merged.dependencies has $n entries"
    else
        fail "build-flakes_${who}.json.deps.node.merged.dependencies missing/wrong shape"
    fi
done

# 5b. build-flakes_{desktop,termux}.json must carry a usable fleet picture.
#
# This used to check gen-claude-md.sh, which generated ~/.claude/CLAUDE.md from
# these files. That generator is GONE, and deliberately: CLAUDE.md is a one-char
# stub now and the principles/reference content it used to hold is injected by
# the cloud-marketplace plugins (SessionStart / UserPromptSubmit hooks) that live
# in da_my-ai's claude SoT. Nobody removed this check when that happened, and
# nobody saw it fail either — the script was hardcoded to $HOME/git/cloud, the
# name this repo had before the rename, so it exited at check 0 for months.
#
# What survives is the half that still means something: the consumed DATA must
# be shaped like a fleet. A generator can be replaced; a build-flakes file with
# no vms is broken for whatever reads it next.
for who in desktop termux; do
    BUILD="$DIST/build-flakes_${who}.json"
    if jq -e '(.vms | length > 0) and (.services | length > 0)' "$BUILD" >/dev/null 2>&1; then
        v=$(jq '.vms | length' "$BUILD")
        s=$(jq '.services | length' "$BUILD")
        pass "build-flakes_${who}.json has $v vms + $s services"
    else
        fail "build-flakes_${who}.json missing vms or services"
    fi
done

# 5c. cb_containers-builders/ship-services.sh must reference build-builders.json
SHIP="$HOME/git/cloud-infra-desktop/cb_containers-builders/src/docker/ship-services.sh"
if [ -f "$SHIP" ] && grep -q "build-builders.json" "$SHIP"; then
    pass "ship-services.sh references build-builders.json"
else
    fail "ship-services.sh missing build-builders.json reference"
fi
BUILD="$DIST/build-builders.json"
if jq -e '(.gha.vms | length > 0) and (.gha.services | length > 0)' "$BUILD" >/dev/null 2>&1; then
    v=$(jq '.gha.vms | length' "$BUILD")
    s=$(jq '.gha.services | length' "$BUILD")
    pass "build-builders.json.gha has $v vms + $s services"
else
    fail "build-builders.json.gha missing vms or services (expected by ship-services.sh)"
fi

# 5d. cloud-data/secrets/secrets.sh must reference build-secrets.json
SEC="$HOME/git/cloud-data/secrets/secrets.sh"
if [ -f "$SEC" ] && grep -q "build-secrets.json" "$SEC"; then
    pass "secrets.sh references build-secrets.json"
else
    fail "secrets.sh missing build-secrets.json reference"
fi
if jq -e '(.services_env_vars | length > 0)' "$DIST/build-secrets.json" >/dev/null 2>&1; then
    s=$(jq '.services_env_vars | length' "$DIST/build-secrets.json")
    pass "build-secrets.json.services_env_vars has $s services"
else
    fail "build-secrets.json.services_env_vars empty or missing"
fi

# 5e. Simulate the ship-services.sh slice extraction to prove jq selector works.
TMP_GHA=$(mktemp)
trap 'rm -f "$TMP_GHA"' EXIT
if jq '.gha' "$DIST/build-builders.json" > "$TMP_GHA" 2>/dev/null \
   && jq -e '.vms and .services' "$TMP_GHA" >/dev/null 2>&1; then
    pass "ship-services.sh slice extraction (jq '.gha') yields a working gha-config"
else
    fail "ship-services.sh slice extraction (jq '.gha') produces invalid output"
fi

# 5f. Simulate the secrets.sh extraction.
TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_GHA" "$TMP_ENV"' EXIT
if jq '.services_env_vars' "$DIST/build-secrets.json" > "$TMP_ENV" 2>/dev/null \
   && jq -e 'type == "object" and (length > 0)' "$TMP_ENV" >/dev/null 2>&1; then
    pass "secrets.sh slice extraction (jq '.services_env_vars') yields env-var map"
else
    fail "secrets.sh slice extraction produces invalid output"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "════════════════════════════════════════════"
    echo "test-external-consumers: PASS"
    echo "════════════════════════════════════════════"
    exit 0
else
    echo "════════════════════════════════════════════"
    echo "test-external-consumers: FAIL ($FAILS check(s))"
    echo "════════════════════════════════════════════"
    exit 1
fi
