#!/usr/bin/env bash
# Unit test for the tag-and-manifest construction logic of step_docker
# (cloud-ship-container-step-build-docker.sh).
#
# It does NOT exercise docker/ssh — it extracts the PURE tag-construction
# decision that step_docker makes (single-arch pair vs multi-arch per-arch
# tags + manifest-create commands) into a standalone function whose body
# mirrors the engine 1:1, then asserts the contract:
#   - single arch  → exactly :latest, -binaries:latest ; ZERO manifests
#   - multi  arch  → per-arch :<arch>, -binaries:<arch>
#                    + `docker manifest create --amend` for :latest (img+bin)
#
# This mirror covers the base :latest / -binaries:latest pair only — the
# original 2026-07-15 contract, from before a commit-sha tag existed at all.
# PLAN-ghcr-artifacts.md item 1 (2026-08-25) reintroduced a reproducible
# <image>:<git-sha12> tag on EVERY path (pushed alongside :latest, gated on
# GIT_SHA12 being resolvable — never forced), because a deploy now needs a
# non-moving pointer to pull by; VMs still default to :latest until items
# 2-4 wire a caller that supplies one. That tagging (+ digest capture +
# buildx-vs-classic degrade) is covered by
# ghcr-artifacts-step-docker-sha-digest.test.sh, executed against the REAL
# script rather than this hand-mirrored one.
set -euo pipefail

# ── Pure logic mirrored from _docker_build_push_arch + the DISPATCH block ──
# Echoes three labelled sections so assertions can grep deterministically:
#   BUILD_TAG <tag>      — every --tag passed to `docker build`
#   PUSH <tag>           — every `docker push` target
#   MANIFEST_CREATE <line> — every `docker manifest create` command (multi only)
plan_docker_tags() {
    local _full="$1" _bin="$2"; shift 2
    local -a _arches=("$@")
    local _count=${#_arches[@]} _a

    if [ "$_count" -eq 1 ]; then
        # Single-arch path: :latest + -binaries:latest (no SHA tag).
        # _docker_build_push_arch "$ARCH" "latest" "latest"
        echo "BUILD_TAG ${_full}:latest"
        echo "BUILD_TAG ${_bin}:latest"
        echo "PUSH ${_full}:latest"
        echo "PUSH ${_bin}:latest"
        # NO manifest in single-arch mode.
    else
        # Multi-arch path: per-arch tags then :latest manifest stitch.
        local _img_arch_tags="" _bin_arch_tags=""
        for _a in "${_arches[@]}"; do
            # _docker_build_push_arch "$_a" "$_a" "$_a"
            echo "BUILD_TAG ${_full}:${_a}"
            echo "BUILD_TAG ${_bin}:${_a}"
            echo "PUSH ${_full}:${_a}"
            echo "PUSH ${_bin}:${_a}"
            _img_arch_tags="${_img_arch_tags} ${_full}:${_a}"
            _bin_arch_tags="${_bin_arch_tags} ${_bin}:${_a}"
        done
        echo "MANIFEST_CREATE docker manifest create --amend ${_full}:latest${_img_arch_tags}"
        echo "MANIFEST_CREATE docker manifest create --amend ${_bin}:latest${_bin_arch_tags}"
    fi
}

FULL="ghcr.io/diegonmarcos/cloud-data-reports"
BIN="ghcr.io/diegonmarcos/cloud-data-reports-binaries"

FAILS=0; PASSES=0
pass() { PASSES=$((PASSES+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS+1)); }

assert_has()  { if grep -qxF "$2" <<<"$1"; then pass; else fail "missing: $2"; fi; }
assert_count(){ local n; n=$(grep -cE "$2" <<<"$1" || true); if [ "$n" -eq "$3" ]; then pass; else fail "expected $3 of /$2/, got $n"; fi; }
assert_absent(){ if grep -qE "$2" <<<"$1"; then fail "$3"; else pass; fi; }

# Case 1: single arch (arm64) — :latest pair, no manifest, no SHA
OUT=$(plan_docker_tags "$FULL" "$BIN" "arm64")
assert_has "$OUT" "BUILD_TAG ${FULL}:latest"
assert_has "$OUT" "BUILD_TAG ${BIN}:latest"
assert_has "$OUT" "PUSH ${FULL}:latest"
assert_has "$OUT" "PUSH ${BIN}:latest"
assert_count "$OUT" "^BUILD_TAG " 2
assert_count "$OUT" "^PUSH " 2
assert_count "$OUT" "^MANIFEST_CREATE " 0   # ZERO manifest commands
assert_absent "$OUT" "(${FULL}|${BIN}):arm64\b" "single-arch leaked a per-arch :arm64 tag"
# no 40-hex or any commit-sha-shaped tag
assert_absent "$OUT" ":[0-9a-f]{7,40}(\b|-)" "single-arch leaked a commit-SHA tag"

# Case 1b: single arch (amd64) — same pair
OUT=$(plan_docker_tags "$FULL" "$BIN" "amd64")
assert_has "$OUT" "BUILD_TAG ${FULL}:latest"
assert_has "$OUT" "BUILD_TAG ${BIN}:latest"
assert_count "$OUT" "^MANIFEST_CREATE " 0

# Case 2: multi arch (amd64,arm64) — per-arch tags + :latest manifests only
OUT=$(plan_docker_tags "$FULL" "$BIN" "amd64" "arm64")
assert_has "$OUT" "BUILD_TAG ${FULL}:amd64"
assert_has "$OUT" "BUILD_TAG ${FULL}:arm64"
assert_has "$OUT" "BUILD_TAG ${BIN}:amd64"
assert_has "$OUT" "BUILD_TAG ${BIN}:arm64"
assert_has "$OUT" "PUSH ${FULL}:amd64"
assert_has "$OUT" "PUSH ${BIN}:arm64"
# manifest create commands — exact strings, :latest only
assert_has "$OUT" "MANIFEST_CREATE docker manifest create --amend ${FULL}:latest ${FULL}:amd64 ${FULL}:arm64"
assert_has "$OUT" "MANIFEST_CREATE docker manifest create --amend ${BIN}:latest ${BIN}:amd64 ${BIN}:arm64"
assert_count "$OUT" "^MANIFEST_CREATE " 2
# negative: no bare :latest build tag in multi-arch (only per-arch are built)
assert_absent "$OUT" "^BUILD_TAG ${FULL}:latest$" "multi-arch built a bare :latest tag (should only be a manifest)"
# negative: no SHA-shaped tag or SHA manifest
assert_absent "$OUT" ":[0-9a-f]{7,40}(\b|-)" "multi-arch leaked a commit-SHA tag"

if [ "$FAILS" -eq 0 ]; then
    printf 'RESULT: ALL %d ASSERTIONS PASSED\n' "$PASSES"
    exit 0
else
    printf 'RESULT: %d FAILED, %d PASSED\n' "$FAILS" "$PASSES"
    exit 1
fi
