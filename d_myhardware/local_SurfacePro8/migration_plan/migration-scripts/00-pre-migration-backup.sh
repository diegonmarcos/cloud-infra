#!/bin/bash
# =============================================================================
# PRE-MIGRATION BACKUP SCRIPT
# Run on current Ubuntu system BEFORE migration
# =============================================================================

set -e

BACKUP_DIR="${1:-/media/diego/backup/surfacepro8-migration-$(date +%Y%m%d)}"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     PRE-MIGRATION BACKUP                                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Backup destination: $BACKUP_DIR"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"/{home,configs,packages,keys}

# =============================================================================
# 1. EXPORT PACKAGE LISTS
# =============================================================================
echo "[1/6] Exporting package lists..."

# APT packages
dpkg --get-selections > "$BACKUP_DIR/packages/apt-selections.txt"
apt-mark showmanual > "$BACKUP_DIR/packages/apt-manual.txt"

# Pip packages
pip freeze > "$BACKUP_DIR/packages/pip-freeze.txt" 2>/dev/null || true
pip list --user > "$BACKUP_DIR/packages/pip-user.txt" 2>/dev/null || true

# Snap packages
snap list > "$BACKUP_DIR/packages/snap-list.txt" 2>/dev/null || true

# Flatpak packages
flatpak list --app > "$BACKUP_DIR/packages/flatpak-apps.txt" 2>/dev/null || true

# NPM global packages
npm list -g --depth=0 > "$BACKUP_DIR/packages/npm-global.txt" 2>/dev/null || true

# Ruby gems
gem list > "$BACKUP_DIR/packages/gem-list.txt" 2>/dev/null || true

# VS Code extensions
code --list-extensions > "$BACKUP_DIR/packages/vscode-extensions.txt" 2>/dev/null || true

echo "   Package lists exported."

# =============================================================================
# 2. BACKUP CONFIGURATION FILES
# =============================================================================
echo "[2/6] Backing up configuration files..."

# Shell configs
cp ~/.bashrc "$BACKUP_DIR/configs/" 2>/dev/null || true
cp ~/.zshrc "$BACKUP_DIR/configs/" 2>/dev/null || true
cp ~/.profile "$BACKUP_DIR/configs/" 2>/dev/null || true
cp -r ~/.config/fish "$BACKUP_DIR/configs/fish" 2>/dev/null || true
cp ~/.p10k.zsh "$BACKUP_DIR/configs/" 2>/dev/null || true

# Git config
cp ~/.gitconfig "$BACKUP_DIR/configs/" 2>/dev/null || true

# SSH config (not keys - those are separate)
cp ~/.ssh/config "$BACKUP_DIR/configs/ssh-config" 2>/dev/null || true

# VS Code settings
cp -r ~/.config/Code/User/settings.json "$BACKUP_DIR/configs/vscode-settings.json" 2>/dev/null || true
cp -r ~/.config/Code/User/keybindings.json "$BACKUP_DIR/configs/vscode-keybindings.json" 2>/dev/null || true

# Starship config
cp ~/.config/starship.toml "$BACKUP_DIR/configs/" 2>/dev/null || true

echo "   Configuration files backed up."

# =============================================================================
# 3. BACKUP KEYS (ENCRYPTED)
# =============================================================================
echo "[3/6] Backing up SSH and GPG keys..."
echo "   WARNING: Keys will be stored - ensure backup drive is secure!"

# SSH keys
cp -r ~/.ssh "$BACKUP_DIR/keys/ssh" 2>/dev/null || true
chmod 700 "$BACKUP_DIR/keys/ssh"
chmod 600 "$BACKUP_DIR/keys/ssh"/* 2>/dev/null || true

# GPG keys
gpg --export --armor > "$BACKUP_DIR/keys/gpg-public.asc" 2>/dev/null || true
gpg --export-secret-keys --armor > "$BACKUP_DIR/keys/gpg-private.asc" 2>/dev/null || true
gpg --export-ownertrust > "$BACKUP_DIR/keys/gpg-ownertrust.txt" 2>/dev/null || true

echo "   Keys backed up."

# =============================================================================
# 4. BACKUP HOME DIRECTORIES
# =============================================================================
echo "[4/6] Backing up home directories..."

# Documents (including Git repos)
if [ -d ~/Documents ]; then
    echo "   Syncing ~/Documents..."
    rsync -avP --progress ~/Documents/ "$BACKUP_DIR/home/Documents/"
fi

# Projects
if [ -d ~/Projects ]; then
    echo "   Syncing ~/Projects..."
    rsync -avP --progress ~/Projects/ "$BACKUP_DIR/home/Projects/"
fi

# Poetry venv configs (not the venvs themselves)
if [ -d ~/poetry_venv_1 ]; then
    echo "   Backing up poetry project..."
    cp ~/poetry_venv_1/pyproject.toml "$BACKUP_DIR/home/" 2>/dev/null || true
    cp ~/poetry_venv_1/poetry.lock "$BACKUP_DIR/home/" 2>/dev/null || true
fi

echo "   Home directories backed up."

# =============================================================================
# 5. BACKUP BROWSER DATA
# =============================================================================
echo "[5/6] Backing up browser bookmarks..."

# Firefox bookmarks
if [ -d ~/.mozilla/firefox ]; then
    FIREFOX_PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -name "*.default*" -type d | head -1)
    if [ -n "$FIREFOX_PROFILE" ]; then
        cp "$FIREFOX_PROFILE/places.sqlite" "$BACKUP_DIR/configs/firefox-places.sqlite" 2>/dev/null || true
    fi
fi

# Brave/Chrome bookmarks
if [ -f ~/.config/BraveSoftware/Brave-Browser/Default/Bookmarks ]; then
    cp ~/.config/BraveSoftware/Brave-Browser/Default/Bookmarks "$BACKUP_DIR/configs/brave-bookmarks.json" 2>/dev/null || true
fi

if [ -f ~/.config/google-chrome/Default/Bookmarks ]; then
    cp ~/.config/google-chrome/Default/Bookmarks "$BACKUP_DIR/configs/chrome-bookmarks.json" 2>/dev/null || true
fi

echo "   Browser bookmarks backed up."

# =============================================================================
# 6. CREATE BACKUP MANIFEST
# =============================================================================
echo "[6/6] Creating backup manifest..."

cat > "$BACKUP_DIR/MANIFEST.txt" << EOF
Surface Pro 8 Migration Backup
==============================
Date: $(date)
Hostname: $(hostname)
User: $(whoami)
Source OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
Kernel: $(uname -r)

Contents:
---------
/packages/     - Package lists from apt, pip, snap, npm, gems, vscode
/configs/      - Shell configs, git config, SSH config, VS Code settings
/keys/         - SSH keys and GPG keys (SECURE THIS!)
/home/         - Documents, Projects, and other home directories

Restore Notes:
--------------
1. Keys should be restored with proper permissions (700/600)
2. Package lists are for reference - use new migration scripts
3. Browser bookmarks can be imported after browser installation
EOF

# Calculate backup size
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     BACKUP COMPLETE                                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Backup location: $BACKUP_DIR"
echo "Total size: $BACKUP_SIZE"
echo ""
echo "IMPORTANT: Verify the backup before proceeding with migration!"
echo "           Keep the backup drive secure - it contains keys!"
