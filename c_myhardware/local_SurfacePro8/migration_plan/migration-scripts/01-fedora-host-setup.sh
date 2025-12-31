#!/bin/bash
# =============================================================================
# FEDORA HOST SETUP FOR SURFACE PRO 8
# Run after fresh Fedora installation
# =============================================================================

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     FEDORA HOST SETUP - SURFACE PRO 8                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "Please run as regular user, not root. Script will use sudo when needed."
    exit 1
fi

# =============================================================================
# 1. ENABLE RPM FUSION REPOSITORIES
# =============================================================================
echo "[1/8] Enabling RPM Fusion repositories..."
sudo dnf install -y \
    https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# =============================================================================
# 2. ADD LINUX-SURFACE REPOSITORY
# =============================================================================
echo "[2/8] Adding linux-surface repository..."
sudo dnf config-manager --add-repo=https://pkg.surfacelinux.com/fedora/linux-surface.repo

# Import GPG key
sudo rpm --import https://pkg.surfacelinux.com/fedora/linux-surface.asc

# =============================================================================
# 3. INSTALL SURFACE KERNEL AND DRIVERS
# =============================================================================
echo "[3/8] Installing Surface kernel and drivers..."
sudo dnf install -y \
    kernel-surface \
    kernel-surface-devel \
    iptsd \
    libwacom-surface

# Install surface-secureboot-mok if secure boot is enabled
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    echo "   Secure Boot detected. Installing MOK..."
    sudo dnf install -y surface-secureboot-mok
    echo "   NOTE: You will need to enroll the MOK key on next boot."
fi

# =============================================================================
# 4. INSTALL CONTAINERIZATION TOOLS
# =============================================================================
echo "[4/8] Installing containerization tools..."
sudo dnf install -y \
    podman \
    podman-compose \
    distrobox \
    buildah \
    skopeo

# Enable podman socket for Docker compatibility
systemctl --user enable podman.socket
systemctl --user start podman.socket

# =============================================================================
# 5. INSTALL FLATPAK AND CONFIGURE FLATHUB
# =============================================================================
echo "[5/8] Setting up Flatpak..."
sudo dnf install -y flatpak

# Add Flathub repository
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# 6. INSTALL ESSENTIAL HOST PACKAGES
# =============================================================================
echo "[6/8] Installing essential packages..."
sudo dnf install -y \
    # Desktop
    plasma-desktop \
    plasma-workspace \
    sddm \
    konsole \
    dolphin \
    kate \
    spectacle \
    ark \
    gwenview \
    okular \
    kcalc \
    # System
    NetworkManager \
    bluez \
    pipewire \
    wireplumber \
    # Utils
    rclone \
    fuse3 \
    htop \
    wget \
    curl \
    git \
    # Security
    firewalld \
    # Fonts
    google-noto-fonts-common \
    google-noto-sans-fonts \
    google-noto-serif-fonts \
    # Power management
    power-profiles-daemon \
    # Filesystem
    btrfs-progs \
    cryptsetup

# =============================================================================
# 7. CONFIGURE SERVICES
# =============================================================================
echo "[7/8] Configuring services..."

# Enable display manager
sudo systemctl enable sddm
sudo systemctl set-default graphical.target

# Enable Surface touch daemon
sudo systemctl enable iptsd

# Enable Bluetooth
sudo systemctl enable bluetooth

# Enable firewall
sudo systemctl enable firewalld
sudo systemctl start firewalld

# Configure firewall defaults
sudo firewall-cmd --set-default-zone=home
sudo firewall-cmd --permanent --add-service=ssh

# Enable power profiles
sudo systemctl enable power-profiles-daemon

# =============================================================================
# 8. CONFIGURE BTRFS MAINTENANCE (if using Btrfs)
# =============================================================================
echo "[8/8] Configuring Btrfs maintenance..."

if mount | grep -q "on / type btrfs"; then
    # Install snapper for snapshots
    sudo dnf install -y snapper

    # Create snapper config for root
    sudo snapper -c root create-config /

    # Enable automatic timeline snapshots
    sudo systemctl enable snapper-timeline.timer
    sudo systemctl enable snapper-cleanup.timer
    sudo systemctl start snapper-timeline.timer
    sudo systemctl start snapper-cleanup.timer

    # Enable periodic scrub
    sudo systemctl enable btrfs-scrub@-.timer
    sudo systemctl start btrfs-scrub@-.timer

    echo "   Btrfs maintenance configured with Snapper."
else
    echo "   Not using Btrfs, skipping maintenance setup."
fi

# =============================================================================
# COMPLETION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     HOST SETUP COMPLETE                                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Reboot the system"
echo "  2. At boot, select 'Surface' kernel from GRUB"
echo "  3. If Secure Boot MOK enrolled, confirm enrollment"
echo "  4. Run: ./02-install-flatpak-apps.sh"
echo "  5. Run: ./03-create-arch-dev.sh"
echo ""
echo "Recommended: sudo reboot"
