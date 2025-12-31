#!/bin/bash
# =============================================================================
# INSTALL PYTHON ENVIRONMENT WITH POETRY
# Run INSIDE the arch-dev Distrobox container
# =============================================================================

set -e

# Check if running inside container
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    echo "This script should be run INSIDE the Distrobox container."
    echo "Run: distrobox enter arch-dev"
    echo "Then: ./05-install-python-env.sh"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     PYTHON ENVIRONMENT SETUP WITH POETRY                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# INSTALL PYTHON AND PYENV
# =============================================================================
echo "[1/5] Installing Python ecosystem..."

sudo pacman -S --noconfirm \
    python \
    python-pip \
    python-pipx \
    pyenv

# Install pyenv-virtualenv plugin
if [ ! -d ~/.pyenv/plugins/pyenv-virtualenv ]; then
    git clone https://github.com/pyenv/pyenv-virtualenv.git ~/.pyenv/plugins/pyenv-virtualenv
fi

# =============================================================================
# INSTALL POETRY
# =============================================================================
echo "[2/5] Installing Poetry..."

# Install Poetry via official installer (recommended)
curl -sSL https://install.python-poetry.org | python3 -

# Add Poetry to PATH
export PATH="$HOME/.local/bin:$PATH"

# Verify installation
poetry --version

# =============================================================================
# CONFIGURE POETRY
# =============================================================================
echo "[3/5] Configuring Poetry..."

# Create venvs inside project directory (.venv/)
poetry config virtualenvs.in-project true

# Use active Python version
poetry config virtualenvs.prefer-active-python true

# Enable parallel installs
poetry config installer.parallel true

# Configure PyPI as default source
poetry config repositories.pypi https://pypi.org/simple/

# =============================================================================
# INSTALL GLOBAL CLI TOOLS VIA PIPX
# =============================================================================
echo "[4/5] Installing global Python tools via pipx..."

# Ensure pipx is in PATH
export PATH="$HOME/.local/bin:$PATH"

# Code quality tools
pipx install black
pipx install ruff
pipx install mypy
pipx install pre-commit
pipx install isort

# Development tools
pipx install httpie
pipx install rich-cli
pipx install yt-dlp
pipx install cookiecutter

# Documentation
pipx install mkdocs
pipx install sphinx

# Jupyter (for notebooks)
pipx install jupyterlab

# =============================================================================
# CREATE TEMPLATE PROJECT
# =============================================================================
echo "[5/5] Creating template Poetry project..."

TEMPLATE_DIR="$HOME/Projects/.poetry-template"
mkdir -p "$HOME/Projects"

if [ ! -d "$TEMPLATE_DIR" ]; then
    mkdir -p "$TEMPLATE_DIR"
    cd "$TEMPLATE_DIR"

    # Initialize Poetry project
    poetry init --name "template-project" \
        --description "Template Python project" \
        --author "Diego <diego@example.com>" \
        --python "^3.11" \
        --no-interaction

    # Add common dependencies
    cat >> pyproject.toml << 'EOF'

[tool.poetry.group.dev.dependencies]
pytest = "^8.0"
pytest-cov = "^4.1"
black = "^24.0"
ruff = "^0.3"
mypy = "^1.9"
pre-commit = "^3.6"

[tool.ruff]
line-length = 88
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP"]

[tool.black]
line-length = 88
target-version = ["py311"]

[tool.mypy]
python_version = "3.11"
strict = true
EOF

    echo "Template project created at: $TEMPLATE_DIR"
fi

# =============================================================================
# SHELL CONFIGURATION FOR POETRY/PYENV
# =============================================================================
echo "Configuring shell for Poetry and pyenv..."

# Fish config
mkdir -p ~/.config/fish/conf.d
cat > ~/.config/fish/conf.d/python.fish << 'EOF'
# Poetry
fish_add_path ~/.local/bin

# Pyenv
set -gx PYENV_ROOT $HOME/.pyenv
fish_add_path $PYENV_ROOT/bin

# Initialize pyenv
if command -v pyenv > /dev/null
    pyenv init - | source
    pyenv virtualenv-init - | source
end

# Poetry completions
if command -v poetry > /dev/null
    poetry completions fish > ~/.config/fish/completions/poetry.fish 2>/dev/null
end
EOF

# Bash/Zsh config
cat >> ~/.profile << 'EOF'

# Pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv &> /dev/null; then
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)"
fi

# Poetry
export PATH="$HOME/.local/bin:$PATH"
EOF

# =============================================================================
# COMPLETION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     PYTHON ENVIRONMENT SETUP COMPLETE                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Poetry configuration:"
echo "  - Venvs location: In-project (.venv/)"
echo "  - Parallel install: Enabled"
echo ""
echo "Global tools installed (via pipx):"
echo "  - black, ruff, mypy, pre-commit, isort"
echo "  - httpie, rich-cli, yt-dlp, cookiecutter"
echo "  - mkdocs, sphinx, jupyterlab"
echo ""
echo "Usage:"
echo "  Create new project:  poetry new my-project"
echo "  Init in existing:    poetry init"
echo "  Add dependency:      poetry add <package>"
echo "  Add dev dependency:  poetry add --group dev <package>"
echo "  Activate venv:       poetry shell"
echo "  Run command:         poetry run <command>"
echo ""
echo "Template project: $TEMPLATE_DIR"
echo ""
echo "Next: Run ./06-configure-shells.sh"
