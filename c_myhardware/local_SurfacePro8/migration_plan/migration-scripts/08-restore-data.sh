#!/bin/bash
# =============================================================================
# RESTORE DATA FROM BACKUP
# Run after container setup to restore data from pre-migration backup
# =============================================================================

set -e

BACKUP_DIR="${1:-}"

if [ -z "$BACKUP_DIR" ]; then
    echo "Usage: $0 /path/to/backup"
    echo ""
    echo "Example: $0 /media/diego/backup/surfacepro8-migration-20241202"
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory not found: $BACKUP_DIR"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     RESTORE DATA FROM BACKUP                                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Backup source: $BACKUP_DIR"
echo ""

# =============================================================================
# 1. RESTORE SSH KEYS
# =============================================================================
echo "[1/5] Restoring SSH keys..."

if [ -d "$BACKUP_DIR/keys/ssh" ]; then
    # Backup existing SSH directory
    if [ -d ~/.ssh ]; then
        mv ~/.ssh ~/.ssh.old.$(date +%Y%m%d)
    fi

    # Copy SSH keys
    cp -r "$BACKUP_DIR/keys/ssh" ~/.ssh

    # Fix permissions
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/id_* 2>/dev/null || true
    chmod 644 ~/.ssh/*.pub 2>/dev/null || true
    chmod 644 ~/.ssh/config 2>/dev/null || true
    chmod 644 ~/.ssh/known_hosts 2>/dev/null || true

    echo "   SSH keys restored."
else
    echo "   No SSH backup found, skipping."
fi

# =============================================================================
# 2. RESTORE GPG KEYS
# =============================================================================
echo "[2/5] Restoring GPG keys..."

if [ -f "$BACKUP_DIR/keys/gpg-private.asc" ]; then
    # Import public keys
    gpg --import "$BACKUP_DIR/keys/gpg-public.asc" 2>/dev/null || true

    # Import private keys
    gpg --import "$BACKUP_DIR/keys/gpg-private.asc" 2>/dev/null || true

    # Import trust
    gpg --import-ownertrust < "$BACKUP_DIR/keys/gpg-ownertrust.txt" 2>/dev/null || true

    echo "   GPG keys restored."
else
    echo "   No GPG backup found, skipping."
fi

# =============================================================================
# 3. RESTORE DOCUMENTS
# =============================================================================
echo "[3/5] Restoring Documents..."

if [ -d "$BACKUP_DIR/home/Documents" ]; then
    mkdir -p ~/Documents

    echo "   Syncing Documents (this may take a while)..."
    rsync -avP --progress "$BACKUP_DIR/home/Documents/" ~/Documents/

    echo "   Documents restored."
else
    echo "   No Documents backup found, skipping."
fi

# =============================================================================
# 4. RESTORE PROJECTS
# =============================================================================
echo "[4/5] Restoring Projects..."

if [ -d "$BACKUP_DIR/home/Projects" ]; then
    mkdir -p ~/Projects

    echo "   Syncing Projects..."
    rsync -avP --progress "$BACKUP_DIR/home/Projects/" ~/Projects/

    echo "   Projects restored."
else
    echo "   No Projects backup found, skipping."
fi

# =============================================================================
# 5. RESTORE GIT CONFIG
# =============================================================================
echo "[5/5] Restoring Git configuration..."

if [ -f "$BACKUP_DIR/configs/.gitconfig" ]; then
    cp "$BACKUP_DIR/configs/.gitconfig" ~/.gitconfig
    echo "   Git config restored."
else
    echo "   No Git config backup found, skipping."
fi

# =============================================================================
# VERIFY RESTORATION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     RESTORATION COMPLETE                                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Restored:"

if [ -d ~/.ssh ]; then
    echo "  ✓ SSH keys: $(ls ~/.ssh | wc -l) files"
fi

if gpg --list-secret-keys 2>/dev/null | grep -q "sec"; then
    echo "  ✓ GPG keys: $(gpg --list-secret-keys 2>/dev/null | grep -c 'sec') secret keys"
fi

if [ -d ~/Documents ]; then
    echo "  ✓ Documents: $(du -sh ~/Documents 2>/dev/null | cut -f1)"
fi

if [ -d ~/Projects ]; then
    echo "  ✓ Projects: $(du -sh ~/Projects 2>/dev/null | cut -f1)"
fi

if [ -f ~/.gitconfig ]; then
    echo "  ✓ Git config"
fi

echo ""
echo "Manual steps remaining:"
echo "  1. Import browser bookmarks (Settings → Import)"
echo "  2. Configure rclone for Google Drive: rclone config"
echo "  3. Re-install Poetry project dependencies: cd project && poetry install"
echo "  4. Test SSH connections: ssh -T git@github.com"
