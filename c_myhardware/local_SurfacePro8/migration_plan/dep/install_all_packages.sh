#!/bin/bash
# MASTER INSTALLATION SCRIPT
# Installs all packages across all package managers
# This script orchestrates the installation of:
#   - APT packages (157 manual)
#   - Python pip packages (94 manual)
#   - Node.js npm packages (2 global)
#   - Snap packages (11 applications)
#   - RubyGems (9 manual)
#   - VS Code extensions (48 extensions)

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     COMPLETE SYSTEM PACKAGE INSTALLATION                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "This script will install packages from:"
echo "  [1] APT (157 packages)"
echo "  [2] Python pip (94 packages)"
echo "  [3] npm (2 packages)"
echo "  [4] Snap (11 applications)"
echo "  [5] RubyGems (9 gems)"
echo "  [6] VS Code Extensions (48 extensions)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 1
fi

# Function to run script if it exists
run_script() {
    local script=$1
    local name=$2
    
    if [ -f "$SCRIPT_DIR/$script" ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "Installing $name..."
        echo "═══════════════════════════════════════════════════════════════"
        bash "$SCRIPT_DIR/$script"
    else
        echo "Warning: $script not found, skipping $name"
    fi
}

# Run installations in order
run_script "install_apt_packages.sh" "APT Packages"
run_script "install_pip_packages.sh" "Python Packages"
run_script "install_npm_packages.sh" "Node.js Packages"
run_script "install_snap_packages.sh" "Snap Packages"
run_script "install_gem_packages.sh" "RubyGems"
run_script "install_vscode_extensions.sh" "VS Code Extensions"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     ALL PACKAGE INSTALLATIONS COMPLETE!                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Summary:"
echo "  ✓ APT: 157 packages + ~3,119 dependencies"
echo "  ✓ Python pip: 94 packages + dependencies"
echo "  ✓ Node.js npm: 2 global packages"
echo "  ✓ Snap: 11 applications + runtime dependencies"
echo "  ✓ RubyGems: 9 gems + dependencies"
echo "  ✓ VS Code: 48 extensions"
echo ""
echo "Your system should now match the documented configuration!"
