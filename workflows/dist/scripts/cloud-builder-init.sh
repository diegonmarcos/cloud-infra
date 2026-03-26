#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder-init.sh — CI/CD init inside cloud-ci container    ║
# ║                                                                  ║
# ║ Sets up SSH + SOPS from env vars, then runs the requested script.║
# ║ Repo must already be cloned at /workspace (done by GHA template).║
# ║                                                                  ║
# ║ Required env vars:                                               ║
# ║   SSH_KEY    — SSH private key for target VM                     ║
# ║   SSH_HOST   — Target VM hostname/IP                             ║
# ║   SSH_USER   — Target VM SSH user                                ║
# ║   SSH_ALIAS  — SSH config alias (e.g. gcp-proxy)                ║
# ║   SOPS_AGE_KEY — SOPS age private key                           ║
# ║                                                                  ║
# ║ Usage: cloud-builder-init.sh <script> [args...]                  ║
# ║   e.g. cloud-builder-init.sh ship-vm.sh gcp-proxy               ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

# ── SSH to target VM ─────────────────────────────────────────────
mkdir -p ~/.ssh
echo "$SSH_KEY" > ~/.ssh/id_deploy
chmod 600 ~/.ssh/id_deploy
cat > ~/.ssh/config <<EOF
Host ${SSH_ALIAS}
  HostName ${SSH_HOST}
  User ${SSH_USER}
  IdentityFile ~/.ssh/id_deploy
  StrictHostKeyChecking no
  ServerAliveInterval 30
  ServerAliveCountMax 10
EOF
chmod 600 ~/.ssh/config

# ── SOPS ─────────────────────────────────────────────────────────
mkdir -p ~/.config/sops/age
echo "$SOPS_AGE_KEY" > ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# ── Run ──────────────────────────────────────────────────────────
CMD="${1:?Usage: cloud-builder-init.sh <script> [args...]}"
shift
exec bash ".github/workflows/scripts/$CMD" "$@"
