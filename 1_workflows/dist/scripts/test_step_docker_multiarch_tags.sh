#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/test_step_docker_multiarch_tags.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Unit test for the tag-and-manifest construction logic of step_docker
# (cloud-ship-container-step-build-docker.sh).
#
# It does NOT exercise docker/ssh — it extracts the PURE tag-construction
# decision that step_docker makes (single-arch triple vs multi-arch per-arch
# tags + manifest-create commands) into a standalone function whose body
# mirrors the engine 1:1, then asserts the contract:
#   - single arch  → exactly :latest, :$SHA_TAG, -binaries:latest ; ZERO manifests
#   - multi  arch  → per-arch :<arch>, -binaries:<arch>, :$SHA_TAG-<arch>
#                    + `docker manifest create --amend` for :latest (img+bin)
#                    and :$SHA_TAG
set -euo pipefail

# ── Pure logic mirrored from _docker_build_push_arch + the DISPATCH block ──
# Echoes three labelled sections so assertions can grep deterministically:
#   BUILD_TAG <tag>      — every --tag passed to `docker build`
#   PUSH <tag>           — every `docker push` target
#   MANIFEST_CREATE <line> — every `docker manifest create` command (multi only)
plan_docker_tags() {
    local _full="$1" _bin="$2" _sha="$3"; shift 3
    local -a _arches=("$@")
    local _count=${#_arches[@]} _a

    if [ "$_count" -eq 1 ]; then
        # Single-arch path: byte-identical legacy triple.
        # _docker_build_push_arch "$ARCH" "latest" "$SHA_TAG" "latest"
        # local branch: --tag :latest --tag :$SHA --tag -binaries:latest
        echo "BUILD_TAG ${_full}:latest"
        echo "BUILD_TAG ${_full}:${_sha}"
        echo "BUILD_TAG ${_bin}:latest"
        echo "PUSH ${_full}:latest"
        echo "PUSH ${_full}:${_sha}"
        echo "PUSH ${_bin}:latest"
        # NO manifest in single-arch mode.
    else
        # Multi-arch path: per-arch tags then manifest stitch.
        local _img_arch_tags="" _bin_arch_tags="" _sha_arch_tags=""
        for _a in "${_arches[@]}"; do
            # _docker_build_push_arch "$_a" "$_a" "$SHA_TAG-$_a" "$_a"
            echo "BUILD_TAG ${_full}:${_a}"
            echo "BUILD_TAG ${_full}:${_sha}-${_a}"
            echo "BUILD_TAG ${_bin}:${_a}"
            echo "PUSH ${_full}:${_a}"
            echo "PUSH ${_full}:${_sha}-${_a}"
            echo "PUSH ${_bin}:${_a}"
            _img_arch_tags="${_img_arch_tags} ${_full}:${_a}"
            _bin_arch_tags="${_bin_arch_tags} ${_bin}:${_a}"
            _sha_arch_tags="${_sha_arch_tags} ${_full}:${_sha}-${_a}"
        done
        echo "MANIFEST_CREATE docker manifest create --amend ${_full}:latest${_img_arch_tags}"
        echo "MANIFEST_CREATE docker manifest create --amend ${_bin}:latest${_bin_arch_tags}"
        echo "MANIFEST_CREATE docker manifest create --amend ${_full}:${_sha}${_sha_arch_tags}"
    fi
}

FULL="ghcr.io/diegonmarcos/cloud-data-reports"
BIN="ghcr.io/diegonmarcos/cloud-data-reports-binaries"
SHA="deadbeef"

FAILS=0; PASSES=0
pass() { PASSES=$((PASSES+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS+1)); }

assert_has()  { if grep -qxF "$2" <<<"$1"; then pass; else fail "missing: $2"; fi; }
assert_count(){ local n; n=$(grep -cE "$2" <<<"$1" || true); if [ "$n" -eq "$3" ]; then pass; else fail "expected $3 of /$2/, got $n"; fi; }

# Case 1: single arch (arm64) — byte-identical legacy triple, no manifest
OUT=$(plan_docker_tags "$FULL" "$BIN" "$SHA" "arm64")
assert_has "$OUT" "BUILD_TAG ${FULL}:latest"
assert_has "$OUT" "BUILD_TAG ${FULL}:${SHA}"
assert_has "$OUT" "BUILD_TAG ${BIN}:latest"
assert_has "$OUT" "PUSH ${FULL}:latest"
assert_has "$OUT" "PUSH ${FULL}:${SHA}"
assert_has "$OUT" "PUSH ${BIN}:latest"
assert_count "$OUT" "^BUILD_TAG " 3
assert_count "$OUT" "^PUSH " 3
assert_count "$OUT" "^MANIFEST_CREATE " 0   # ZERO manifest commands
# negative: no per-arch tag leaked
if grep -qE "(${FULL}|${BIN}):arm64\b" <<<"$OUT"; then fail "single-arch leaked a per-arch :arm64 tag"; else pass; fi

# Case 1b: single arch (amd64) — same triple
OUT=$(plan_docker_tags "$FULL" "$BIN" "$SHA" "amd64")
assert_has "$OUT" "BUILD_TAG ${FULL}:latest"
assert_has "$OUT" "BUILD_TAG ${FULL}:${SHA}"
assert_has "$OUT" "BUILD_TAG ${BIN}:latest"
assert_count "$OUT" "^MANIFEST_CREATE " 0

# Case 2: multi arch (amd64,arm64) — per-arch tags + manifests
OUT=$(plan_docker_tags "$FULL" "$BIN" "$SHA" "amd64" "arm64")
# per-arch primary + binaries tags
assert_has "$OUT" "BUILD_TAG ${FULL}:amd64"
assert_has "$OUT" "BUILD_TAG ${FULL}:arm64"
assert_has "$OUT" "BUILD_TAG ${BIN}:amd64"
assert_has "$OUT" "BUILD_TAG ${BIN}:arm64"
# per-arch sha tags
assert_has "$OUT" "BUILD_TAG ${FULL}:${SHA}-amd64"
assert_has "$OUT" "BUILD_TAG ${FULL}:${SHA}-arm64"
# pushes
assert_has "$OUT" "PUSH ${FULL}:amd64"
assert_has "$OUT" "PUSH ${BIN}:arm64"
assert_has "$OUT" "PUSH ${FULL}:${SHA}-arm64"
# manifest create commands — exact strings
assert_has "$OUT" "MANIFEST_CREATE docker manifest create --amend ${FULL}:latest ${FULL}:amd64 ${FULL}:arm64"
assert_has "$OUT" "MANIFEST_CREATE docker manifest create --amend ${BIN}:latest ${BIN}:amd64 ${BIN}:arm64"
assert_has "$OUT" "MANIFEST_CREATE docker manifest create --amend ${FULL}:${SHA} ${FULL}:${SHA}-amd64 ${FULL}:${SHA}-arm64"
assert_count "$OUT" "^MANIFEST_CREATE " 3
# negative: no bare :latest build tag in multi-arch (only per-arch are built)
if grep -qxF "BUILD_TAG ${FULL}:latest" <<<"$OUT"; then fail "multi-arch built a bare :latest tag (should only be a manifest)"; else pass; fi

if [ "$FAILS" -eq 0 ]; then
    printf 'RESULT: ALL %d ASSERTIONS PASSED\n' "$PASSES"
    exit 0
else
    printf 'RESULT: %d FAILED, %d PASSED\n' "$FAILS" "$PASSES"
    exit 1
fi
