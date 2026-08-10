#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder-secrets.sh — Setup SSH + SOPS from env vars       ║
# ║                                                                  ║
# ║ Writes SSH key + config and SOPS age key from environment.       ║
# ║ Called by cloud-builder.sh, not directly.                        ║
# ║                                                                  ║
# ║ Required env: SSH_KEY, SSH_HOST, SSH_USER, SSH_ALIAS, SOPS_AGE_KEY║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

# ── SSH ──────────────────────────────────────────────────────────
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
echo "SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
