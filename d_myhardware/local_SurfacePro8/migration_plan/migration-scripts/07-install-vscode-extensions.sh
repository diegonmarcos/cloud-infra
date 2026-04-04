#!/bin/bash
# =============================================================================
# INSTALL VS CODE EXTENSIONS
# Can be run inside container or on host (Flatpak VS Code)
# =============================================================================

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     INSTALLING VS CODE EXTENSIONS                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if VS Code is available
if ! command -v code &> /dev/null; then
    echo "VS Code not found. Install it first:"
    echo "  - Inside container: yay -S visual-studio-code-bin"
    echo "  - On host: flatpak install flathub com.visualstudio.code"
    exit 1
fi

# =============================================================================
# AI ASSISTANTS
# =============================================================================
echo "[1/9] Installing AI assistant extensions..."
code --install-extension anthropic.claude-code || true
code --install-extension github.copilot || true
code --install-extension github.copilot-chat || true
code --install-extension google.geminicodeassist || true

# =============================================================================
# C/C++ DEVELOPMENT
# =============================================================================
echo "[2/9] Installing C/C++ extensions..."
code --install-extension ms-vscode.cpptools || true
code --install-extension ms-vscode.cpptools-extension-pack || true
code --install-extension ms-vscode.cpptools-themes || true
code --install-extension ms-vscode.cmake-tools || true
code --install-extension twxs.cmake || true
code --install-extension llvm-vs-code-extensions.lldb-dap || true
code --install-extension vadimcn.vscode-lldb || true
code --install-extension cs128.cs128-clang-tidy || true
code --install-extension cschlosser.doxdocgen || true
code --install-extension ms-vscode.makefile-tools || true
code --install-extension technosophos.vscode-make || true

# =============================================================================
# PYTHON
# =============================================================================
echo "[3/9] Installing Python extensions..."
code --install-extension ms-python.python || true
code --install-extension ms-python.vscode-pylance || true
code --install-extension ms-python.debugpy || true
code --install-extension ms-python.vscode-python-envs || true
code --install-extension ms-toolsai.jupyter || true
code --install-extension ms-toolsai.jupyter-keymap || true
code --install-extension ms-toolsai.jupyter-renderers || true
code --install-extension ms-toolsai.vscode-jupyter-cell-tags || true
code --install-extension ms-toolsai.vscode-jupyter-slideshow || true

# =============================================================================
# WEB DEVELOPMENT
# =============================================================================
echo "[4/9] Installing Web development extensions..."
code --install-extension ritwickdey.liveserver || true
code --install-extension ms-vscode.live-server || true
code --install-extension esbenp.prettier-vscode || true
code --install-extension dbaeumer.vscode-eslint || true

# =============================================================================
# OTHER LANGUAGES
# =============================================================================
echo "[5/9] Installing other language extensions..."
code --install-extension golang.go || true
code --install-extension rust-lang.rust-analyzer || true

# =============================================================================
# GIT & VERSION CONTROL
# =============================================================================
echo "[6/9] Installing Git extensions..."
code --install-extension eamodio.gitlens || true
code --install-extension donjayamanne.githistory || true

# =============================================================================
# CONTAINERS & DEVOPS
# =============================================================================
echo "[7/9] Installing container extensions..."
code --install-extension ms-azuretools.vscode-docker || true
code --install-extension ms-vscode-remote.remote-containers || true

# =============================================================================
# DOCUMENTATION & MARKDOWN
# =============================================================================
echo "[8/9] Installing documentation extensions..."
code --install-extension bierner.markdown-mermaid || true
code --install-extension tomoki1207.pdf || true

# =============================================================================
# UTILITIES
# =============================================================================
echo "[9/9] Installing utility extensions..."
code --install-extension wakatime.vscode-wakatime || true
code --install-extension hediet.debug-visualizer || true
code --install-extension psioniq.psi-header || true

# =============================================================================
# CONFIGURE VS CODE SETTINGS
# =============================================================================
echo "Configuring VS Code settings..."

# Find settings.json location
if [ -d ~/.config/Code/User ]; then
    SETTINGS_DIR=~/.config/Code/User
elif [ -d ~/.var/app/com.visualstudio.code/config/Code/User ]; then
    SETTINGS_DIR=~/.var/app/com.visualstudio.code/config/Code/User
else
    mkdir -p ~/.config/Code/User
    SETTINGS_DIR=~/.config/Code/User
fi

# Backup existing settings
if [ -f "$SETTINGS_DIR/settings.json" ]; then
    cp "$SETTINGS_DIR/settings.json" "$SETTINGS_DIR/settings.json.backup"
fi

cat > "$SETTINGS_DIR/settings.json" << 'SETTINGS'
{
    // Editor
    "editor.fontSize": 14,
    "editor.fontFamily": "'JetBrains Mono', 'Fira Code', 'Droid Sans Mono', monospace",
    "editor.fontLigatures": true,
    "editor.tabSize": 4,
    "editor.formatOnSave": true,
    "editor.wordWrap": "on",
    "editor.minimap.enabled": false,
    "editor.lineNumbers": "relative",
    "editor.cursorBlinking": "smooth",
    "editor.smoothScrolling": true,
    "editor.bracketPairColorization.enabled": true,

    // Terminal
    "terminal.integrated.fontFamily": "'JetBrains Mono', monospace",
    "terminal.integrated.fontSize": 13,
    "terminal.integrated.defaultProfile.linux": "fish",

    // Files
    "files.autoSave": "afterDelay",
    "files.autoSaveDelay": 1000,
    "files.trimTrailingWhitespace": true,
    "files.insertFinalNewline": true,

    // Git
    "git.autofetch": true,
    "git.confirmSync": false,

    // Python
    "python.defaultInterpreterPath": ".venv/bin/python",
    "[python]": {
        "editor.defaultFormatter": "ms-python.black-formatter",
        "editor.formatOnSave": true,
        "editor.codeActionsOnSave": {
            "source.organizeImports": "explicit"
        }
    },

    // C/C++
    "C_Cpp.default.compilerPath": "/usr/bin/clang",
    "C_Cpp.default.cStandard": "c17",
    "C_Cpp.default.cppStandard": "c++20",
    "C_Cpp.clang_format_fallbackStyle": "Google",

    // Rust
    "[rust]": {
        "editor.defaultFormatter": "rust-lang.rust-analyzer"
    },

    // Go
    "[go]": {
        "editor.defaultFormatter": "golang.go"
    },

    // JSON
    "[json]": {
        "editor.defaultFormatter": "esbenp.prettier-vscode"
    },

    // Markdown
    "[markdown]": {
        "editor.wordWrap": "on",
        "editor.quickSuggestions": {
            "other": true,
            "comments": true,
            "strings": true
        }
    },

    // Copilot
    "github.copilot.enable": {
        "*": true,
        "plaintext": false,
        "markdown": true
    },

    // Workbench
    "workbench.startupEditor": "none",
    "workbench.sideBar.location": "left",

    // Explorer
    "explorer.confirmDelete": false,
    "explorer.confirmDragAndDrop": false,

    // Extensions
    "extensions.autoUpdate": true
}
SETTINGS

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     VS CODE EXTENSIONS INSTALLED                               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Installed extensions:"
code --list-extensions | wc -l
echo ""
echo "Settings saved to: $SETTINGS_DIR/settings.json"
echo ""
echo "Tip: Install JetBrains Mono font for best experience:"
echo "  sudo pacman -S ttf-jetbrains-mono"
