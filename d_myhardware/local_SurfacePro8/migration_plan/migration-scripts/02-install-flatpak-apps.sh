#!/bin/bash
# =============================================================================
# FLATPAK APPLICATIONS INSTALLATION
# Sandboxed GUI applications for Fedora host
# =============================================================================

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     INSTALLING FLATPAK APPLICATIONS                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Ensure Flathub is added
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# BROWSERS
# =============================================================================
echo "[1/7] Installing browsers..."
flatpak install -y flathub com.brave.Browser
flatpak install -y flathub com.google.Chrome

# =============================================================================
# COMMUNICATION
# =============================================================================
echo "[2/7] Installing communication apps..."
flatpak install -y flathub com.slack.Slack
flatpak install -y flathub com.discordapp.Discord
flatpak install -y flathub org.mozilla.Thunderbird
flatpak install -y flathub im.element.Element

# =============================================================================
# PRODUCTIVITY
# =============================================================================
echo "[3/7] Installing productivity apps..."
flatpak install -y flathub md.obsidian.Obsidian
flatpak install -y flathub org.libreoffice.LibreOffice

# =============================================================================
# GRAPHICS & DESIGN
# =============================================================================
echo "[4/7] Installing graphics apps..."
flatpak install -y flathub org.kde.krita
flatpak install -y flathub net.scribus.Scribus
flatpak install -y flathub org.gimp.GIMP

# =============================================================================
# MEDIA
# =============================================================================
echo "[5/7] Installing media apps..."
flatpak install -y flathub org.videolan.VLC
flatpak install -y flathub com.spotify.Client

# =============================================================================
# SECURITY / VPN
# =============================================================================
echo "[6/7] Installing security apps..."
flatpak install -y flathub com.protonvpn.www

# =============================================================================
# DEVELOPMENT (GUI Only - CLI tools go in Distrobox)
# =============================================================================
echo "[7/7] Installing development GUI apps..."
flatpak install -y flathub com.visualstudio.code

# Note: VS Code in Flatpak has some limitations with terminal/shell integration
# Consider installing VS Code inside Distrobox for better dev experience
# Or use Flatpak's host filesystem permissions

# Grant VS Code access to home directory
flatpak override --user --filesystem=home com.visualstudio.code

# =============================================================================
# COMPLETION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     FLATPAK INSTALLATION COMPLETE                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Installed applications:"
flatpak list --app --columns=application,name | sort
echo ""
echo "Note: VS Code can also be installed inside Distrobox for better"
echo "      terminal integration. Run ./03-create-arch-dev.sh next."
