#!/bin/bash
# =============================================================================
# INSTALL DEVELOPMENT TOOLS
# Run INSIDE the arch-dev Distrobox container
# =============================================================================

set -e

# Check if running inside container
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    echo "This script should be run INSIDE the Distrobox container."
    echo "Run: distrobox enter arch-dev"
    echo "Then: ./04-install-dev-tools.sh"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     INSTALLING DEVELOPMENT TOOLS (Arch Container)              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# C/C++ TOOLCHAIN
# =============================================================================
echo "[1/10] Installing C/C++ toolchain..."
sudo pacman -S --noconfirm \
    clang \
    lldb \
    clang-tools-extra \
    llvm \
    lld \
    cmake \
    meson \
    ninja \
    valgrind \
    bear \
    gdb \
    # Libraries
    glfw \
    freeglut \
    mesa \
    libx11 \
    libxrandr \
    libxext

# =============================================================================
# RUST
# =============================================================================
echo "[2/10] Installing Rust..."
sudo pacman -S --noconfirm rustup
rustup default stable
rustup component add rust-analyzer clippy rustfmt

# =============================================================================
# GO
# =============================================================================
echo "[3/10] Installing Go..."
sudo pacman -S --noconfirm go gopls

# Add Go to PATH
mkdir -p ~/go/{bin,src,pkg}
if ! grep -q 'GOPATH' ~/.profile 2>/dev/null; then
    echo 'export GOPATH=$HOME/go' >> ~/.profile
    echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.profile
fi

# =============================================================================
# JAVA
# =============================================================================
echo "[4/10] Installing Java..."
sudo pacman -S --noconfirm \
    jdk-openjdk \
    maven \
    gradle

# =============================================================================
# JAVASCRIPT / NODE.JS
# =============================================================================
echo "[5/10] Installing Node.js ecosystem..."
sudo pacman -S --noconfirm \
    nodejs \
    npm \
    yarn

# Install pnpm (faster package manager)
npm install -g pnpm

# Install nvm via AUR for version management
yay -S --noconfirm nvm

# =============================================================================
# RUBY
# =============================================================================
echo "[6/10] Installing Ruby..."
sudo pacman -S --noconfirm \
    ruby \
    rubygems

# Install common gems
gem install bundler jekyll

# =============================================================================
# DATABASES
# =============================================================================
echo "[7/10] Installing database tools..."
sudo pacman -S --noconfirm \
    postgresql \
    mariadb \
    sqlite \
    redis \
    # Clients
    pgcli \
    mycli \
    litecli

# =============================================================================
# WEB SERVERS
# =============================================================================
echo "[8/10] Installing web servers..."
sudo pacman -S --noconfirm \
    nginx \
    apache

# =============================================================================
# CLOUD & DEVOPS
# =============================================================================
echo "[9/10] Installing cloud and DevOps tools..."
sudo pacman -S --noconfirm \
    kubectl \
    helm \
    terraform \
    ansible

# Install cloud CLIs via AUR
yay -S --noconfirm \
    aws-cli-v2 \
    azure-cli \
    google-cloud-cli

# =============================================================================
# DOCUMENTATION & MISC
# =============================================================================
echo "[10/10] Installing documentation and misc tools..."
sudo pacman -S --noconfirm \
    doxygen \
    graphviz \
    texlive-basic \
    texlive-latex \
    pandoc \
    imagemagick \
    ffmpeg

# =============================================================================
# INSTALL VS CODE (inside container for better integration)
# =============================================================================
echo "Installing VS Code..."
yay -S --noconfirm visual-studio-code-bin

# Export VS Code to host desktop
distrobox-export --app code 2>/dev/null || true

# =============================================================================
# INSTALL AI CLI TOOLS
# =============================================================================
echo "Installing AI CLI tools..."

# Claude Code
npm install -g @anthropic-ai/claude-code 2>/dev/null || true

# Gemini CLI
npm install -g @google/gemini-cli 2>/dev/null || true

# Ollama (local LLM runner)
yay -S --noconfirm ollama-bin 2>/dev/null || true

# =============================================================================
# COMPLETION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     DEVELOPMENT TOOLS INSTALLED                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Installed toolchains:"
echo "  - C/C++: clang, gcc, cmake, valgrind"
echo "  - Rust: rustup (stable), rust-analyzer"
echo "  - Go: go, gopls"
echo "  - Java: OpenJDK, Maven, Gradle"
echo "  - Node.js: node, npm, yarn, pnpm, nvm"
echo "  - Ruby: ruby, bundler, jekyll"
echo "  - Databases: PostgreSQL, MariaDB, SQLite, Redis"
echo "  - Cloud: kubectl, helm, terraform, ansible"
echo "  - Cloud CLIs: aws, az, gcloud"
echo ""
echo "Next: Run ./05-install-python-env.sh"
