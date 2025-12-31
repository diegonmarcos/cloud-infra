# Surface Pro 8 Migration Plan
## Ubuntu (Kubuntu) → Fedora + Distrobox (Arch) with Poetry Python Isolation

---

## 🎯 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SURFACE PRO 8 STORAGE                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────────────────────────────────────┐ │
│  │   Windows 11     │  │              LUKS2 Encrypted Partition            │ │
│  │   (Minimal)      │  │                                                   │ │
│  │   ~60GB          │  │  ┌─────────────────────────────────────────────┐  │ │
│  │                  │  │  │          FEDORA 41+ (Silverblue/KDE)        │  │ │
│  │  - Camera/Video  │  │  │                                             │  │ │
│  │  - Teams/Zoom    │  │  │  Host: Minimal, Immutable-Style             │  │ │
│  │  - Emergency     │  │  │  ├── Wayland + KDE Plasma                   │  │ │
│  │    Recovery      │  │  │  ├── Surface Kernel (linux-surface)         │  │ │
│  │                  │  │  │  ├── Flatpak (GUI Apps Only)                │  │ │
│  │                  │  │  │  └── Distrobox + Podman                     │  │ │
│  │                  │  │  │                                             │  │ │
│  │                  │  │  │  ┌─────────────────────────────────────┐    │  │ │
│  │                  │  │  │  │     DISTROBOX: ARCH LINUX           │    │  │ │
│  │                  │  │  │  │     (Dev Environment Container)     │    │  │ │
│  │                  │  │  │  │                                     │    │  │ │
│  │                  │  │  │  │  ├── ALL Dev Tools (gcc, clang...)  │    │  │ │
│  │                  │  │  │  │  ├── Fish + Zsh + Starship          │    │  │ │
│  │                  │  │  │  │  │                                   │    │  │ │
│  │                  │  │  │  │  │  ┌─────────────────────────────┐ │    │  │ │
│  │                  │  │  │  │  │  │  POETRY VIRTUAL ENVS        │ │    │  │ │
│  │                  │  │  │  │  │  │  (Per-Project Python)       │ │    │  │ │
│  │                  │  │  │  │  │  │                             │ │    │  │ │
│  │                  │  │  │  │  │  │  ├── pyproject.toml         │ │    │  │ │
│  │                  │  │  │  │  │  │  ├── poetry.lock            │ │    │  │ │
│  │                  │  │  │  │  │  │  └── .venv/                 │ │    │  │ │
│  │                  │  │  │  │  │  └─────────────────────────────┘ │    │  │ │
│  │                  │  │  │  │  │                                   │    │  │ │
│  │                  │  │  │  │  └── Webservers, Monitoring         │    │  │ │
│  │                  │  │  │  └─────────────────────────────────────┘    │  │ │
│  │                  │  │  │                                             │  │ │
│  │                  │  │  └─────────────────────────────────────────────┘  │ │
│  └──────────────────┘  └──────────────────────────────────────────────────┘ │
│                                                                              │
│  ESP (EFI System Partition) - Shared by both OS (~512MB)                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Partition Layout (Recommended)

| Partition | Size | Type | Mount | Purpose |
|-----------|------|------|-------|---------|
| ESP | 512MB | EFI | /boot/efi | GRUB/systemd-boot shared |
| Windows | 60GB | NTFS | - | Minimal Win11 (camera/video calls) |
| Boot | 1GB | ext4 | /boot | Unencrypted kernel/initramfs |
| LUKS Root | REST | LUKS2→Btrfs | / | Encrypted Fedora installation |

### Btrfs Subvolumes (Inside LUKS)
```
@           →  /
@home       →  /home
@var        →  /var
@snapshots  →  /.snapshots
@containers →  /var/lib/containers
```

**Why Btrfs?**
- Native snapshots before major changes
- Compression (zstd) - saves SSD space
- Easy rollback with Snapper
- Copy-on-write efficiency

---

## 🔐 Security Architecture

### Layer 1: Full Disk Encryption (LUKS2)
```bash
# LUKS2 with Argon2id KDF (stronger than PBKDF2)
cryptsetup luksFormat --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  /dev/nvme0n1p3
```

### Layer 2: Secure Boot Integration
```bash
# Surface Pro 8 requires signed kernel
# linux-surface provides signed kernels
# MOK (Machine Owner Key) enrollment
mokutil --import /path/to/surface-kernel-key.der
```

### Layer 3: Host Isolation (Fedora Minimal)
- Host runs ONLY:
  - Wayland compositor (KDE)
  - Podman/Distrobox
  - Flatpak runtime
  - SystemD services
- NO development tools on host
- NO Python/Node/Ruby on host system

### Layer 4: Container Isolation (Distrobox)
- All dev work happens inside Arch container
- Container shares $HOME (configurable)
- Network namespace isolated (optional)
- Can run GUI apps via host Wayland

### Layer 5: Python Isolation (Poetry)
- Each project has its own virtualenv
- `poetry.lock` ensures reproducible builds
- System Python never polluted
- Easy export/import of dependencies

---

## 📦 Package Migration Strategy

### Phase 1: Fedora Host (Minimal)

#### DNF Packages (Host Only)
```yaml
# fedora-host-packages.yaml
host_packages:
  essential:
    - linux-surface        # Surface Pro kernel
    - iptsd               # Touch/pen daemon
    - libwacom-surface    # Wacom drivers
    - cryptsetup          # LUKS management
    - btrfs-progs         # Btrfs utilities
    - grub2-efi-x64       # Bootloader
    - shim-x64            # Secure boot

  containerization:
    - podman              # Container runtime
    - distrobox           # Container wrapper
    - buildah             # Image building

  flatpak_support:
    - flatpak             # App sandboxing
    - xdg-desktop-portal-kde  # KDE integration

  desktop:
    - plasma-desktop      # KDE Plasma
    - sddm                # Display manager
    - konsole             # Terminal (host)
    - dolphin             # File manager

  cloud_sync:
    - rclone              # Google Drive sync
```

#### Flatpak Apps (Sandboxed GUI)
```yaml
# flatpak-apps.yaml
flatpak_apps:
  browsers:
    - com.brave.Browser
    - com.google.Chrome

  communication:
    - com.slack.Slack
    - com.discordapp.Discord
    - org.mozilla.Thunderbird
    - im.element.Element

  productivity:
    - md.obsidian.Obsidian
    - org.kde.krita
    - net.scribus.Scribus
    - org.libreoffice.LibreOffice

  media:
    - org.videolan.VLC

  security:
    - com.protonvpn.www    # ProtonVPN

  development_gui:
    - com.visualstudio.code  # VS Code Flatpak
    # OR install in distrobox for better integration
```

### Phase 2: Distrobox Arch Container

#### Create Container
```bash
# Create persistent Arch development container
distrobox create \
  --name arch-dev \
  --image archlinux:latest \
  --home ~/distrobox-homes/arch-dev \
  --additional-packages "base-devel git fish zsh"

# Enter container
distrobox enter arch-dev
```

#### Arch Packages (Development)
```yaml
# arch-dev-packages.yaml
# To be installed with: pacman -S <package>

base_development:
  - base-devel            # build tools (gcc, make, etc)
  - git
  - git-lfs
  - github-cli

compilers_toolchains:
  c_cpp:
    - clang
    - lldb
    - clang-tools-extra   # clang-tidy, clangd
    - cmake
    - meson
    - ninja
    - valgrind
    - bear                # compile_commands.json

  llvm:
    - llvm
    - lld

  rust:
    - rustup              # Then: rustup default stable

  go:
    - go

  java:
    - jdk-openjdk         # OpenJDK 21+
    - maven
    - gradle

  javascript:
    - nodejs
    - npm
    - yarn
    - pnpm                # Faster package manager

  ruby:
    - ruby
    - rubygems

python_ecosystem:
  - python
  - python-pip
  - python-pipx
  - python-poetry         # Key: Poetry for venv management
  - pyenv                 # Multiple Python versions

shells_terminals:
  - fish
  - zsh
  - starship             # Cross-shell prompt
  - fzf                  # Fuzzy finder
  - bat                  # Better cat
  - exa                  # Better ls (or eza)
  - ripgrep              # Better grep
  - fd                   # Better find
  - delta                # Better git diff
  - zoxide               # Smart cd

text_editors:
  - neovim
  - vim
  - helix                # Modern vim-like

containers_cloud:
  - docker               # Inside distrobox via podman socket
  - kubectl
  - helm
  - terraform
  - ansible
  - aws-cli-v2
  - azure-cli
  - google-cloud-cli

databases:
  - postgresql
  - mariadb
  - sqlite
  - redis

webservers:
  - nginx
  - apache

documentation:
  - doxygen
  - graphviz
  - texlive-most         # LaTeX
  - pandoc               # Document conversion

graphics_libs:
  - mesa
  - glfw
  - freeglut
  - sdl2

utilities:
  - htop
  - btop                 # Better htop
  - ncdu                 # Disk usage
  - tree
  - jq                   # JSON processor
  - yq                   # YAML processor
  - wget
  - curl
  - rsync
  - unzip
  - p7zip
  - wakatime             # Time tracking

aur_packages:  # Via yay or paru
  - visual-studio-code-bin  # Or use Flatpak
  - claude-code-cli
  - gemini-cli
  - ollama-bin
  - nvm                  # Node version manager
```

### Phase 3: Python Environment (Poetry)

#### Global Poetry Config
```bash
# Inside arch-dev container
poetry config virtualenvs.in-project true  # .venv in project folder
poetry config virtualenvs.prefer-active-python true
```

#### Project Structure Template
```
~/Projects/
├── myproject/
│   ├── pyproject.toml    # Poetry project definition
│   ├── poetry.lock       # Locked dependencies
│   ├── .venv/            # Virtual environment
│   ├── src/
│   │   └── myproject/
│   └── tests/
```

#### Example pyproject.toml
```toml
[tool.poetry]
name = "myproject"
version = "0.1.0"
description = "My awesome project"
authors = ["Diego <diego@example.com>"]

[tool.poetry.dependencies]
python = "^3.12"
numpy = "^1.26"
pandas = "^2.2"
requests = "^2.31"

[tool.poetry.group.dev.dependencies]
pytest = "^8.0"
black = "^24.0"
ruff = "^0.3"
mypy = "^1.9"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
```

#### Migrated Python Packages
```yaml
# python-packages.yaml
# Install per-project via: poetry add <package>

core_data_science:
  - numpy
  - pandas
  - scipy
  - scikit-learn
  - matplotlib
  - seaborn
  - plotly
  - jupyter
  - jupyterlab

web_frameworks:
  - fastapi
  - uvicorn
  - flask
  - django
  - requests
  - httpx
  - aiohttp

database:
  - sqlalchemy
  - psycopg2-binary
  - pymongo
  - redis

utilities:
  - rich            # Pretty terminal output
  - typer           # CLI builder
  - pydantic        # Data validation
  - python-dotenv
  - pyyaml
  - jinja2
  - pillow
  - openpyxl
  - python-docx

devtools:
  - black           # Formatter
  - ruff            # Fast linter (replaces flake8, isort)
  - mypy            # Type checker
  - pytest
  - pytest-cov
  - pre-commit

ai_llm:
  - openai
  - anthropic
  - google-generativeai
  - langchain
  - transformers
  - torch           # If GPU available

media:
  - yt-dlp
  - ffmpeg-python

cloud:
  - boto3           # AWS
  - google-cloud-storage
  - azure-storage-blob
```

---

## 🛠️ Installation Scripts

### Script 1: Fedora Post-Install Setup
```bash
#!/bin/bash
# fedora-host-setup.sh
# Run after fresh Fedora installation

set -e

echo "=== Fedora Host Setup for Surface Pro 8 ==="

# 1. Enable RPM Fusion
sudo dnf install -y \
  https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# 2. Add linux-surface repo
sudo dnf config-manager --add-repo=https://pkg.surfacelinux.com/fedora/linux-surface.repo

# 3. Install Surface kernel and drivers
sudo dnf install -y \
  kernel-surface \
  kernel-surface-devel \
  iptsd \
  libwacom-surface

# 4. Install containerization
sudo dnf install -y \
  podman \
  distrobox \
  buildah

# 5. Install Flatpak and Flathub
sudo dnf install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 6. Install KDE essentials
sudo dnf install -y \
  plasma-desktop \
  sddm \
  konsole \
  dolphin \
  kate \
  spectacle

# 7. Cloud sync
sudo dnf install -y rclone

# 8. Enable services
sudo systemctl enable sddm
sudo systemctl enable iptsd

echo "=== Host setup complete. Reboot and select Surface kernel ==="
```

### Script 2: Flatpak Apps Installation
```bash
#!/bin/bash
# install-flatpak-apps.sh

set -e

echo "=== Installing Flatpak Applications ==="

# Browsers
flatpak install -y flathub com.brave.Browser
flatpak install -y flathub com.google.Chrome

# Communication
flatpak install -y flathub com.slack.Slack
flatpak install -y flathub com.discordapp.Discord
flatpak install -y flathub org.mozilla.Thunderbird
flatpak install -y flathub im.element.Element

# Productivity
flatpak install -y flathub md.obsidian.Obsidian
flatpak install -y flathub org.kde.krita
flatpak install -y flathub net.scribus.Scribus

# Development
flatpak install -y flathub com.visualstudio.code

# Security
flatpak install -y flathub com.protonvpn.www

echo "=== Flatpak apps installed ==="
```

### Script 3: Distrobox Arch Container Setup
```bash
#!/bin/bash
# create-arch-dev.sh
# Creates and configures the Arch Linux development container

set -e

CONTAINER_NAME="arch-dev"
CONTAINER_HOME="$HOME/distrobox-homes/$CONTAINER_NAME"

echo "=== Creating Arch Development Container ==="

# Create home directory
mkdir -p "$CONTAINER_HOME"

# Create container
distrobox create \
  --name "$CONTAINER_NAME" \
  --image archlinux:latest \
  --home "$CONTAINER_HOME" \
  --yes

# Enter and setup
distrobox enter "$CONTAINER_NAME" -- bash -c '
  # Initialize pacman
  sudo pacman -Syu --noconfirm

  # Install base development
  sudo pacman -S --noconfirm \
    base-devel \
    git \
    git-lfs \
    github-cli \
    fish \
    zsh \
    starship \
    neovim \
    fzf \
    ripgrep \
    fd \
    bat \
    exa \
    zoxide \
    delta \
    htop \
    btop \
    tree \
    jq \
    wget \
    curl \
    rsync \
    unzip

  # Install yay (AUR helper)
  git clone https://aur.archlinux.org/yay.git /tmp/yay
  cd /tmp/yay && makepkg -si --noconfirm
  rm -rf /tmp/yay

  echo "Base container setup complete!"
'

echo "=== Container created. Enter with: distrobox enter $CONTAINER_NAME ==="
```

### Script 4: Development Tools Installation (Inside Container)
```bash
#!/bin/bash
# install-dev-tools.sh
# Run INSIDE arch-dev container

set -e

echo "=== Installing Development Tools ==="

# C/C++ toolchain
sudo pacman -S --noconfirm \
  clang \
  lldb \
  clang-tools-extra \
  cmake \
  meson \
  ninja \
  valgrind \
  bear

# Python ecosystem
sudo pacman -S --noconfirm \
  python \
  python-pip \
  python-pipx \
  python-poetry

# Node.js
sudo pacman -S --noconfirm \
  nodejs \
  npm \
  yarn

# Rust
sudo pacman -S --noconfirm rustup
rustup default stable

# Go
sudo pacman -S --noconfirm go

# Java
sudo pacman -S --noconfirm jdk-openjdk maven gradle

# Ruby
sudo pacman -S --noconfirm ruby rubygems

# Databases
sudo pacman -S --noconfirm \
  postgresql \
  mariadb \
  sqlite \
  redis

# Web servers
sudo pacman -S --noconfirm nginx

# Documentation
sudo pacman -S --noconfirm \
  doxygen \
  graphviz \
  texlive-basic \
  pandoc

# Cloud tools
sudo pacman -S --noconfirm \
  kubectl \
  helm \
  terraform \
  ansible \
  aws-cli-v2

# AUR packages
yay -S --noconfirm \
  visual-studio-code-bin \
  nvm \
  google-cloud-cli \
  azure-cli

# Configure Poetry
poetry config virtualenvs.in-project true
poetry config virtualenvs.prefer-active-python true

# Install global CLI tools via pipx
pipx install yt-dlp
pipx install black
pipx install ruff
pipx install pre-commit

echo "=== Development tools installed ==="
```

### Script 5: Shell Configuration Migration
```bash
#!/bin/bash
# migrate-shell-configs.sh
# Migrates shell configurations to new system

set -e

CONFIG_SOURCE="$HOME/Documents/Git/back-System/cloud/local_SurfacePro8/shells"

echo "=== Migrating Shell Configurations ==="

# Fish config
mkdir -p ~/.config/fish
cat > ~/.config/fish/config.fish << 'FISHEOF'
### ------------------- ###
### --- FISH CONFIG --- ###
### ------------------- ###

# Path
fish_add_path ~/.local/bin
fish_add_path ~/.cargo/bin
fish_add_path ~/go/bin

# Variables
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx path_to_my_git "$HOME/Documents/Git/"

# Poetry - auto-activate venvs
set -gx POETRY_VIRTUALENVS_IN_PROJECT true

# Aliases - Python
alias py='python3'
alias python='python3'
alias pip='pip3'

# Aliases - Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Aliases - List
alias ll='exa -la --icons'
alias la='exa -a --icons'
alias lt='exa -T --icons'
alias l='exa --icons'

# Aliases - Git
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'
alias gpl='git pull'

# Aliases - Safety
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# Aliases - System
alias df='df -h'
alias du='du -h'
alias free='free -h'

# Aliases - Docker/Podman
alias docker='podman'
alias dps='podman ps'
alias dpsa='podman ps -a'

# Aliases - Development
alias serve='python3 -m http.server'
alias jn='jupyter notebook'

# Functions
function mkcd
    mkdir -p $argv[1]; and cd $argv[1]
end

function extract
    if test -f $argv[1]
        switch $argv[1]
            case '*.tar.bz2'; tar xjf $argv[1]
            case '*.tar.gz'; tar xzf $argv[1]
            case '*.tar.xz'; tar xf $argv[1]
            case '*.bz2'; bunzip2 $argv[1]
            case '*.gz'; gunzip $argv[1]
            case '*.tar'; tar xf $argv[1]
            case '*.zip'; unzip $argv[1]
            case '*.7z'; 7z x $argv[1]
            case '*'; echo "'$argv[1]' cannot be extracted"
        end
    else
        echo "'$argv[1]' is not a valid file"
    end
end

# Poetry wrapper - auto-venv activation
function pyp --description 'Poetry run with auto-install'
    if test (count $argv) -lt 1
        echo "Usage: pyp <package> [args...]"
        return 1
    end

    # Ensure we're in a poetry project
    if not test -f pyproject.toml
        echo "No pyproject.toml found. Initialize with: poetry init"
        return 1
    end

    set target_package $argv[1]
    set extra_args $argv[2..-1]

    echo "Running: poetry run $target_package $extra_args"
    poetry run $target_package $extra_args
end

# Initialize Starship prompt
starship init fish | source

# Startup message
function fish_greeting
    echo ""
    printf "\x1b[1;34mWelcome to Arch Dev Container, %s!\x1b[0m\n" (whoami)
    echo "Type 'exit' to return to host"
    echo ""
end
FISHEOF

# Starship config
mkdir -p ~/.config
cat > ~/.config/starship.toml << 'STARSHIPEOF'
format = """
[](#9A348E)\
$os\
$username\
[](bg:#DA627D fg:#9A348E)\
$directory\
[](fg:#DA627D bg:#FCA17D)\
$git_branch\
$git_status\
[](fg:#FCA17D bg:#86BBD8)\
$python\
$nodejs\
$rust\
$golang\
[](fg:#86BBD8 bg:#06969A)\
$docker_context\
[](fg:#06969A bg:#33658A)\
$time\
[ ](fg:#33658A)\
"""

[username]
show_always = true
style_user = "bg:#9A348E"
style_root = "bg:#9A348E"
format = '[$user ]($style)'
disabled = false

[os]
style = "bg:#9A348E"
disabled = true

[directory]
style = "bg:#DA627D"
format = "[ $path ]($style)"
truncation_length = 3
truncation_symbol = "…/"

[git_branch]
symbol = ""
style = "bg:#FCA17D"
format = '[ $symbol $branch ]($style)'

[git_status]
style = "bg:#FCA17D"
format = '[$all_status$ahead_behind ]($style)'

[python]
symbol = ""
style = "bg:#86BBD8"
format = '[ $symbol ($version) (\($virtualenv\)) ]($style)'

[nodejs]
symbol = ""
style = "bg:#86BBD8"
format = '[ $symbol ($version) ]($style)'

[rust]
symbol = ""
style = "bg:#86BBD8"
format = '[ $symbol ($version) ]($style)'

[golang]
symbol = ""
style = "bg:#86BBD8"
format = '[ $symbol ($version) ]($style)'

[docker_context]
symbol = ""
style = "bg:#06969A"
format = '[ $symbol $context ]($style)'

[time]
disabled = false
time_format = "%R"
style = "bg:#33658A"
format = '[ ♥ $time ]($style)'
STARSHIPEOF

echo "=== Shell configs migrated ==="
```

### Script 6: VS Code Extensions (Inside Container or Host)
```bash
#!/bin/bash
# install-vscode-extensions.sh

set -e

echo "=== Installing VS Code Extensions ==="

EXTENSIONS=(
  # AI Assistants
  "anthropic.claude-code"
  "github.copilot"
  "github.copilot-chat"
  "google.geminicodeassist"

  # C/C++
  "ms-vscode.cpptools"
  "ms-vscode.cpptools-extension-pack"
  "ms-vscode.cmake-tools"
  "llvm-vs-code-extensions.lldb-dap"
  "vadimcn.vscode-lldb"
  "twxs.cmake"
  "cs128.cs128-clang-tidy"
  "cschlosser.doxdocgen"

  # Python
  "ms-python.python"
  "ms-python.vscode-pylance"
  "ms-python.debugpy"
  "ms-toolsai.jupyter"

  # Git
  "eamodio.gitlens"
  "donjayamanne.githistory"

  # Containers
  "ms-azuretools.vscode-docker"
  "ms-vscode-remote.remote-containers"

  # Web
  "ritwickdey.liveserver"
  "esbenp.prettier-vscode"
  "dbaeumer.vscode-eslint"

  # Go
  "golang.go"

  # Rust
  "rust-lang.rust-analyzer"

  # Markdown
  "bierner.markdown-mermaid"

  # Utilities
  "wakatime.vscode-wakatime"
  "tomoki1207.pdf"
)

for ext in "${EXTENSIONS[@]}"; do
  code --install-extension "$ext" || true
done

echo "=== VS Code extensions installed ==="
```

---

## 🚀 Migration Steps

### Pre-Migration Checklist

1. **Backup Everything**
   ```bash
   # On current Ubuntu system
   rsync -avP --progress /home/diego/ /path/to/backup/

   # Export installed packages lists
   dpkg --get-selections > ~/backup/apt-packages.txt
   pip freeze > ~/backup/pip-packages.txt
   code --list-extensions > ~/backup/vscode-extensions.txt
   ```

2. **Document Current Config**
   - Screenshot of partition layout
   - Note BitLocker recovery keys (if Windows encrypted)
   - Export browser bookmarks
   - Export SSH keys (keep secure!)
   - Export GPG keys

3. **Download Required ISOs**
   - Fedora KDE Spin (or Silverblue): `Fedora-KDE-Live-x86_64-41-*.iso`
   - Windows 11 ISO (for reinstall if needed)

4. **Create Bootable USB**
   ```bash
   # Using Ventoy (recommended - supports multiple ISOs)
   # OR
   sudo dd if=Fedora-*.iso of=/dev/sdX bs=4M status=progress
   ```

### Phase 1: Windows Shrink/Reinstall

1. Boot into Windows
2. Run `diskmgmt.msc`
3. Shrink Windows partition to ~60GB
4. **OR** Reinstall Windows fresh with 60GB partition

### Phase 2: Fedora Installation

1. Boot Fedora Live USB
2. Select "Install to Hard Drive"
3. Choose "Custom" partitioning:

   ```
   /dev/nvme0n1p1  512MB  EFI System (keep if exists)
   /dev/nvme0n1p2  60GB   Windows (keep)
   /dev/nvme0n1p3  1GB    /boot ext4 (NEW)
   /dev/nvme0n1p4  REST   LUKS encrypted (NEW)
   ```

4. **Encryption Setup** (installer handles this):
   - Select "Encrypt my data"
   - Choose strong passphrase

5. **Btrfs Setup**:
   - Format LUKS container as Btrfs
   - Mount point: `/`

6. Complete installation

### Phase 3: Post-Install Configuration

```bash
# 1. Update system
sudo dnf update -y

# 2. Run host setup script
chmod +x fedora-host-setup.sh
./fedora-host-setup.sh

# 3. Reboot and select Surface kernel
sudo reboot

# 4. After reboot, install Flatpaks
./install-flatpak-apps.sh

# 5. Create Arch container
./create-arch-dev.sh

# 6. Enter container and install dev tools
distrobox enter arch-dev
./install-dev-tools.sh

# 7. Migrate shell configs
./migrate-shell-configs.sh

# 8. Setup VS Code
./install-vscode-extensions.sh
```

### Phase 4: Data Migration

```bash
# Mount backup drive
sudo mount /dev/sdb1 /mnt/backup

# Restore home directory (selective)
rsync -avP /mnt/backup/Documents ~/
rsync -avP /mnt/backup/Projects ~/
rsync -avP /mnt/backup/.ssh ~/  # Careful with permissions!
rsync -avP /mnt/backup/.gnupg ~/

# Fix SSH permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/*
```

---

## 📁 Final Directory Structure

```
/home/diego/
├── .config/
│   ├── fish/config.fish
│   ├── starship.toml
│   └── ...
├── .local/bin/           # pipx binaries, scripts
├── .ssh/                 # SSH keys
├── .gnupg/              # GPG keys
├── Documents/
│   ├── Git/             # Main code repository
│   │   ├── back-System/
│   │   ├── front-Github_io/
│   │   ├── mylibs/
│   │   └── ...
│   └── Gdrive/          # rclone mount point
├── Projects/            # Poetry projects
│   ├── project-a/
│   │   ├── pyproject.toml
│   │   ├── poetry.lock
│   │   └── .venv/
│   └── project-b/
├── distrobox-homes/     # Container home directories
│   └── arch-dev/
└── poetry_venv_1/       # Legacy global venv (migrate away)
```

---

## 🔄 Daily Workflow

### Starting Development Session
```bash
# 1. Host: Open terminal (Konsole)
# 2. Enter development container
distrobox enter arch-dev

# 3. Navigate to project
cd ~/Documents/Git/my-project

# 4. Activate/create Poetry environment
poetry install     # First time
poetry shell      # Activate venv

# 5. Start coding!
code .            # VS Code
```

### Running Services
```bash
# Inside arch-dev container
# Start webserver
cd ~/Projects/my-webapp
poetry run uvicorn main:app --reload

# Database (inside container)
sudo systemctl start postgresql
# OR use podman
podman run -d -p 5432:5432 postgres:16
```

### GUI Apps from Container
```bash
# Distrobox automatically exports desktop files
# Run VS Code from container
distrobox enter arch-dev
code ~/Documents/Git/my-project

# OR export the app to host menu
distrobox-export --app code
```

---

## 🛡️ Security Best Practices

1. **LUKS Key Management**
   - Store recovery key in password manager
   - Consider FIDO2 key for unlock

2. **Firewall**
   ```bash
   # Host (Fedora)
   sudo firewall-cmd --set-default-zone=drop
   sudo firewall-cmd --permanent --add-service=ssh
   sudo firewall-cmd --reload
   ```

3. **Regular Updates**
   ```bash
   # Host
   sudo dnf upgrade --refresh

   # Container
   distrobox enter arch-dev
   sudo pacman -Syu
   ```

4. **Snapshot Before Major Changes**
   ```bash
   # Btrfs snapshot
   sudo snapper create --description "Before kernel update"
   ```

---

## 📊 Resource Comparison

| Metric | Ubuntu (Current) | Fedora + Distrobox |
|--------|------------------|-------------------|
| Boot time | ~15s | ~10s (lighter) |
| RAM idle | ~2GB | ~1.5GB |
| Disk usage | ~50GB | ~25GB host + 15GB container |
| Security | Good | Excellent (isolation) |
| Update frequency | 6 months | Rolling (Arch) + 6 months (Fedora) |
| Reproducibility | Low (manual) | High (declarative) |

---

## 🆘 Troubleshooting

### Surface Pro 8 Specific

```bash
# Touch not working
sudo systemctl restart iptsd

# Suspend issues
# Add to /etc/default/grub:
# GRUB_CMDLINE_LINUX="mem_sleep_default=deep"
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# WiFi issues
# linux-surface kernel should handle this
# If not: modprobe -r mwifiex_pcie && modprobe mwifiex_pcie
```

### Container Issues

```bash
# Container won't start
podman system reset
distrobox rm arch-dev --force
# Recreate container

# GUI apps not working
distrobox enter arch-dev
xhost +local:

# Permission denied on home files
# Check if home is shared properly in distrobox
```

### Poetry Issues

```bash
# Wrong Python version
poetry env use python3.12

# Corrupted venv
rm -rf .venv
poetry install

# Can't find package
poetry source add pypi https://pypi.org/simple/
```

---

## 📝 Notes

- **Why Fedora over Ubuntu?**: Better OOTB experience for newer hardware, more current packages, better Wayland support
- **Why Arch in container?**: Rolling release = latest dev tools, AUR access, but isolated from host stability
- **Why Poetry over pip?**: Reproducible builds, dependency resolution, project isolation
- **Why Btrfs?**: Snapshots, compression, modern features
- **Why LUKS2?**: Stronger encryption (Argon2id), better performance

---

*Generated: 2025-12-02*
*Migration Plan Version: 1.0*
