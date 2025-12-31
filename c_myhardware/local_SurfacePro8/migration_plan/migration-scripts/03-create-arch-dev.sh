#!/bin/bash
# =============================================================================
# CREATE ARCH LINUX DEVELOPMENT CONTAINER
# Uses Distrobox with Arch Linux for isolated development environment
# =============================================================================

set -e

CONTAINER_NAME="arch-dev"
CONTAINER_IMAGE="archlinux:latest"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     CREATING ARCH DEVELOPMENT CONTAINER                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Container name: $CONTAINER_NAME"
echo "Base image: $CONTAINER_IMAGE"
echo ""

# =============================================================================
# CHECK PREREQUISITES
# =============================================================================
echo "[1/5] Checking prerequisites..."

if ! command -v distrobox &> /dev/null; then
    echo "ERROR: distrobox not found. Run 01-fedora-host-setup.sh first."
    exit 1
fi

if ! command -v podman &> /dev/null; then
    echo "ERROR: podman not found. Run 01-fedora-host-setup.sh first."
    exit 1
fi

# =============================================================================
# CREATE CONTAINER
# =============================================================================
echo "[2/5] Creating Distrobox container..."

# Remove existing container if present
if distrobox list | grep -q "$CONTAINER_NAME"; then
    echo "   Container '$CONTAINER_NAME' exists. Removing..."
    distrobox rm -f "$CONTAINER_NAME"
fi

# Create new container
# --home option shares home directory (default behavior)
distrobox create \
    --name "$CONTAINER_NAME" \
    --image "$CONTAINER_IMAGE" \
    --yes

echo "   Container created."

# =============================================================================
# INITIAL SETUP INSIDE CONTAINER
# =============================================================================
echo "[3/5] Initializing container (this may take a few minutes)..."

distrobox enter "$CONTAINER_NAME" -- bash -c '
set -e

echo "=== Inside container: Initializing Arch Linux ==="

# Initialize pacman keyring
sudo pacman-key --init
sudo pacman-key --populate archlinux

# Update system
sudo pacman -Syu --noconfirm

# Install base development packages
sudo pacman -S --noconfirm \
    base-devel \
    git \
    git-lfs \
    github-cli \
    wget \
    curl \
    rsync \
    unzip \
    p7zip

# Install yay (AUR helper)
if ! command -v yay &> /dev/null; then
    echo "Installing yay..."
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin
    makepkg -si --noconfirm
    cd ~
    rm -rf /tmp/yay-bin
fi

echo "=== Base initialization complete ==="
'

# =============================================================================
# INSTALL SHELLS AND TERMINAL TOOLS
# =============================================================================
echo "[4/5] Installing shells and terminal tools..."

distrobox enter "$CONTAINER_NAME" -- bash -c '
set -e

echo "=== Installing shells and terminal tools ==="

sudo pacman -S --noconfirm \
    fish \
    zsh \
    starship \
    fzf \
    ripgrep \
    fd \
    bat \
    eza \
    zoxide \
    git-delta \
    htop \
    btop \
    ncdu \
    tree \
    jq \
    yq \
    neovim \
    tmux

echo "=== Shells and tools installed ==="
'

# =============================================================================
# CONFIGURE DEFAULT SHELL
# =============================================================================
echo "[5/5] Configuring default shell..."

distrobox enter "$CONTAINER_NAME" -- bash -c '
# Set fish as default shell for container
if [ -f /usr/bin/fish ]; then
    echo "Setting fish as default shell..."
    # Distrobox uses the host user, so we configure via shell init
    mkdir -p ~/.config/distrobox
    echo "fish" > ~/.config/distrobox/default_shell
fi
'

# =============================================================================
# COMPLETION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     CONTAINER CREATED SUCCESSFULLY                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Container: $CONTAINER_NAME"
echo ""
echo "Usage:"
echo "  Enter container:    distrobox enter $CONTAINER_NAME"
echo "  Run command:        distrobox enter $CONTAINER_NAME -- <command>"
echo "  Export app to host: distrobox-export --app <app-name>"
echo ""
echo "Next steps:"
echo "  1. Enter container: distrobox enter $CONTAINER_NAME"
echo "  2. Run: ./04-install-dev-tools.sh"
echo "  3. Run: ./05-install-python-env.sh"
echo "  4. Run: ./06-configure-shells.sh"
