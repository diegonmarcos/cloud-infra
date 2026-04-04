#!/bin/bash
# Snap Packages Installation Script
# Runtimes will be automatically installed as dependencies

set -e

echo "Installing 11 snap applications..."

snap install curl
snap install custom-screen-resolution
snap install element-desktop
snap install firmware-updater
snap install google-cloud-cli
snap install htop
snap install krita
snap install ollama
snap install slack
snap install snapd
snap install thunderbird

echo "Snap packages installation complete!"
