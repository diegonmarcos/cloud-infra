#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ship-hm.sh — Self-contained HM deploy inside cloud-builder     ║
# ║                                                                  ║
# ║  Runs INSIDE the builder container. GHA only passes env vars.    ║
# ║  This script: clones → pulls fresh data → secrets → build → ship ║
# ║                                                                  ║
# ║  Required env: VM, SOPS_AGE_KEY, GITHUB_TOKEN, GITHUB_REPOSITORY║
# ║  SSH keys: OCI_SSH_KEY, GCP_PROXY_SSH_KEY, GCP_T4_SSH_KEY       ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

VM="${VM:?VM env var required}"
REPO="https://github.com/${GITHUB_REPOSITORY:?}.git"

echo "══════════════════════════════════════════"
echo "  Ship HM: $VM"
echo "══════════════════════════════════════════"

# ── 1. Clone fresh ──────────────────────────────────────────────
echo "[1/5] Cloning $REPO"
mkdir -p ~/.ssh
ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null
git config --global --add safe.directory "*"
git clone --depth 2 --recurse-submodules "$REPO" /workspace
cd /workspace
git submodule update --remote
# cloud-data: remote always wins
git -C cloud-data fetch origin main 2>/dev/null && git -C cloud-data reset --hard origin/main 2>/dev/null || true

# ── 2. Setup SSH ────────────────────────────────────────────────
echo "[2/5] Setting up SSH for $VM"
GHA_CONFIG="cloud-data/cloud-data-gha-config.json"
HOST=$(jq -r --arg vm "$VM" '.vms[$vm].wg_ip // .vms[$vm].host' "$GHA_CONFIG")
USER=$(jq -r --arg vm "$VM" '.vms[$vm].user' "$GHA_CONFIG")

case "$VM" in
  gcp-proxy) KEY="${GCP_PROXY_SSH_KEY:-}" ;;
  gcp-t4)    KEY="${GCP_T4_SSH_KEY:-}" ;;
  *)         KEY="${OCI_SSH_KEY:-}" ;;
esac

if [ -z "$KEY" ]; then
  echo "FATAL: No SSH key for $VM"
  exit 1
fi

echo "$KEY" > ~/.ssh/id_deploy
chmod 600 ~/.ssh/id_deploy
cat > ~/.ssh/config <<EOF
Host ${VM}
  HostName ${HOST}
  User ${USER}
  IdentityFile ~/.ssh/id_deploy
  StrictHostKeyChecking no
  ServerAliveInterval 30
  ServerAliveCountMax 10
EOF
chmod 600 ~/.ssh/config

# ── 3. Setup SOPS ──────────────────────────────────────────────
echo "[3/5] Setting up SOPS"
if [ ! -f ~/.config/sops/age/keys.txt ]; then
  mkdir -p ~/.config/sops/age
  echo "${SOPS_AGE_KEY:?SOPS_AGE_KEY required}" > ~/.config/sops/age/keys.txt
fi
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# ── 4. Update builder flake.lock (fresh config.json hash) ──────
echo "[4/5] Updating builder flake inputs"
nix flake update config-json --flake /opt/cloud-builder-flake 2>&1 || echo "[builder] flake update skipped"

# ── 5. Ship ─────────────────────────────────────────────────────
echo "[5/5] Running build.sh ship for $VM"
cd /workspace/b_infra/home-manager/"$VM"
bash build.sh ship 2>&1
