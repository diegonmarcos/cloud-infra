#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 5 tester — cloud-builder SSH mount safety                  ║
# ║                                                                  ║
# ║ Proves:                                                          ║
# ║   compose.yaml must NOT mount host ${HOME}/.ssh directly at      ║
# ║   /root/.ssh. That collision hits strict SSH perm checks when    ║
# ║   the runner UID (≠ 0) owns files inside the container (root).   ║
# ║   Host secrets must mount at /mnt/host-ssh and entrypoint.sh     ║
# ║   copies them into /root/.ssh with chown root:root + chmod.      ║
# ║                                                                  ║
# ║   Source of truth: II_Unix submodule →                          ║
# ║     cb_containers-builders/src/docker/compose.yaml               ║
# ║     cb_containers-builders/src/docker/entrypoint.sh              ║
# ║                                                                  ║
# ║ Usage: bash 1_configs/src/deploy/test/test_cloud_builder_ssh_safety.sh║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Source lives in the unix submodule — check the checked-out copy
COMPOSE=""
ENTRYPOINT=""
for base in \
    "$REPO_ROOT/II_Unix/cb_containers-builders/src/docker" \
    "$REPO_ROOT/a_solutions/infra-bld_cloud-builder-x/src/docker"; do
    if [ -f "$base/compose.yaml" ]; then
        COMPOSE="$base/compose.yaml"
        ENTRYPOINT="$base/entrypoint.sh"
        break
    fi
done

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

if [ -z "$COMPOSE" ]; then
    echo "── cloud-builder source not present in checkout ──"
    echo "  (II_Unix submodule not initialised — nothing to assert)"
    exit 0
fi

echo "── 1: compose.yaml does NOT bind-mount host ~/.ssh at /root/.ssh ──"

if grep -E '^\s*-\s*\$\{HOME\}/\.ssh:/root/\.ssh' "$COMPOSE" >/dev/null; then
    fail "compose.yaml mounts \${HOME}/.ssh directly at /root/.ssh"
    echo "    (breaks SSH owner-check inside container — runner UID ≠ root)" >&2
    grep -nE '\.ssh:/root/\.ssh' "$COMPOSE" | sed 's/^/    /' >&2
else
    pass "no host→/root/.ssh bind mount"
fi

echo ""
echo "── 2: compose.yaml mounts host ~/.ssh at /mnt/host-ssh (neutral path) ──"

if grep -qE '\$\{HOME\}/\.ssh:/mnt/host-ssh' "$COMPOSE"; then
    pass "host ~/.ssh mounted at /mnt/host-ssh"
else
    fail "host ~/.ssh not mounted at /mnt/host-ssh — entrypoint can't copy it in"
fi

echo ""
echo "── 3: entrypoint.sh copies /mnt/host-ssh/* → /root/.ssh with chown ──"

if grep -qE '/mnt/host-ssh' "$ENTRYPOINT" \
   && grep -qiE 'chown root:root .*(ssh|SSH_DIR)' "$ENTRYPOINT"; then
    pass "entrypoint copies from /mnt/host-ssh and re-owns to root"
else
    fail "entrypoint does not copy /mnt/host-ssh → /root/.ssh with chown"
fi

echo ""
echo "── 4: entrypoint.sh always chmod 700 /root/.ssh ──"

if grep -qE 'chmod 700 /root/\.ssh|chmod 700 \$\{?HOME\}?/\.ssh|chmod 700 ~/\.ssh|chmod 700 "\$SSH_DIR"' "$ENTRYPOINT"; then
    pass "entrypoint enforces chmod 700 on /root/.ssh"
else
    fail "entrypoint does not chmod 700 /root/.ssh — SSH will reject loose dir perms"
fi

echo ""
echo "── 5: shellcheck entrypoint.sh ──"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error "$ENTRYPOINT" >/dev/null 2>&1; then
        pass "shellcheck clean: entrypoint.sh"
    else
        fail "shellcheck errors in entrypoint.sh:"
        shellcheck -S error "$ENTRYPOINT" >&2 || true
    fi
else
    echo "  ⚠ shellcheck not installed — skipping"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "══════════════════════════════════════════════"
    echo "Phase 5 cloud-builder SSH safety: PASS"
    echo "══════════════════════════════════════════════"
    exit 0
else
    echo "══════════════════════════════════════════════"
    echo "Phase 5 cloud-builder SSH safety: FAIL"
    echo "══════════════════════════════════════════════"
    exit 1
fi
