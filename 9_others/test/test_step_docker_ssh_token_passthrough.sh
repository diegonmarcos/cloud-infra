#!/usr/bin/env bash
# Test: step_docker SSH-builder branch ships the GHCR token via SSH stdin
# (no vault dependency on the remote VM) and uses pipefail so failures in
# the SSH | while-read pipe propagate instead of silently returning 0.
#
# Bug surfaced 2026-04-27 (ship run 24998852451): /home/ubuntu/git/cloud-vault
# on oci-apps was an empty stub dir; cat'ing the token inside cloud-builder-x
# silently failed; docker login failed; build/push failed; the SSH | while-read
# pipe swallowed the non-zero exit (no pipefail); engine logged a misleading
# "Pushed". MCPs stayed broken at compose-up with "No such image".
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-container-step-build-docker.sh"

[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

FAIL=0

# 1) The SSH-builder branch must NOT bind-mount the host's ~/git/cloud-vault — the
#    remote VM may not have vault. Token is shipped via SSH stdin instead.
if grep -qE '\\?\$HOME/git/cloud-vault.*home/diego/git/cloud-vault' "$SCRIPT"; then
    printf "  FAIL SSH-builder branch still bind-mounts \$HOME/git/cloud-vault — vault may not exist on the remote VM\n"
    FAIL=1
else
    printf "  OK  no host vault bind-mount in SSH-builder branch\n"
fi

# 2) The token must be staged via SSH stdin to a remote temp file.
if grep -qE 'ssh \$SSH_OPTS.*"umask 077.*cat > \$REMOTE_TOKEN_FILE' "$SCRIPT"; then
    printf "  OK  GHCR token shipped via SSH stdin to remote temp file\n"
else
    printf "  FAIL GHCR token is not shipped via SSH stdin — relies on remote vault\n"
    FAIL=1
fi

# 3) Token source must fall back to GITHUB_TOKEN if vault path is missing.
if grep -qE 'GHCR_TOKEN_VAL="\$GITHUB_TOKEN"' "$SCRIPT"; then
    printf "  OK  GITHUB_TOKEN fallback when vault token path missing\n"
else
    printf "  FAIL no GITHUB_TOKEN fallback — runs without vault still fail\n"
    FAIL=1
fi

# 4) The SSH | while-read pipe must run under `set -o pipefail` so failures
#    propagate. Without it, push failures return exit 0 to step_docker.
if awk '/ssh)/,/;;/' "$SCRIPT" | grep -qE 'set -o pipefail'; then
    printf "  OK  pipefail enabled around SSH | while-read pipe\n"
else
    printf "  FAIL pipefail not set — SSH/build/push failures silently return 0 to step_docker\n"
    FAIL=1
fi

# 5) Pipefail must be cleared after the pipe so it doesn't leak into other
#    steps in the same shell.
if grep -qE 'set \+o pipefail' "$SCRIPT"; then
    printf "  OK  pipefail cleared after SSH pipe\n"
else
    printf "  FAIL pipefail not cleared — would leak into subsequent steps in same shell\n"
    FAIL=1
fi

# 6) Cleanup of the staged token file must happen.
if grep -qE 'rm -f \$REMOTE_TOKEN_FILE' "$SCRIPT"; then
    printf "  OK  staged token file cleaned up after build\n"
else
    printf "  FAIL staged token file not cleaned up — token persists on remote VM tmpfs\n"
    FAIL=1
fi

# 7) sh -c body must `cd /workspace` before docker build. Cloud-builder-x's
#    entrypoint cd's to /root/git/cloud-infra BEFORE exec'ing the user command,
#    overriding docker's -w flag. Without explicit cd, docker build runs from
#    /root/git/cloud-infra and can't find Dockerfile rsync'd to /workspace.
if grep -qE "cd /workspace && \\\\?$" "$SCRIPT" || grep -qE 'cd /workspace &&' "$SCRIPT"; then
    printf "  OK  sh -c body explicitly cd's to /workspace (entrypoint cwd guard)\n"
else
    printf "  FAIL sh -c body does not cd to /workspace — entrypoint's cd \$GIT_ROOT/cloud overrides -w\n"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "::error::step_docker SSH token passthrough regression"
    exit 1
fi

echo
echo "step_docker SSH branch ships GHCR token via SSH stdin + uses pipefail — no remote vault dependency, no silent push failures."
