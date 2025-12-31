#!/bin/bash
# =============================================================================
# CONFIGURE SHELLS (Fish, Zsh, Bash)
# Run INSIDE the arch-dev Distrobox container
# =============================================================================

set -e

# Check if running inside container
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    echo "This script should be run INSIDE the Distrobox container."
    echo "Run: distrobox enter arch-dev"
    echo "Then: ./06-configure-shells.sh"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     CONFIGURING SHELLS                                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# FISH CONFIGURATION
# =============================================================================
echo "[1/4] Configuring Fish shell..."

mkdir -p ~/.config/fish/{conf.d,functions,completions}

cat > ~/.config/fish/config.fish << 'FISHCONFIG'
### ------------------- ###
### --- FISH CONFIG --- ###
### ------------------- ###

# =============================================================================
# PATH Configuration
# =============================================================================
fish_add_path ~/.local/bin
fish_add_path ~/.cargo/bin
fish_add_path ~/go/bin
fish_add_path ~/.pyenv/bin

# =============================================================================
# Environment Variables
# =============================================================================
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER "less -R"
set -gx path_to_my_git "$HOME/Documents/Git/"

# Poetry config
set -gx POETRY_VIRTUALENVS_IN_PROJECT true

# Go
set -gx GOPATH $HOME/go

# =============================================================================
# Aliases - Python
# =============================================================================
alias py='python3'
alias python='python3'
alias pip='pip3'

# =============================================================================
# Aliases - Navigation
# =============================================================================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

# =============================================================================
# Aliases - Modern CLI Replacements
# =============================================================================
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first'
alias lt='eza -T --icons --level=2'
alias lta='eza -Ta --icons --level=2'

alias cat='bat --style=plain'
alias catn='bat'

alias grep='rg'
alias find='fd'

alias diff='delta'

# =============================================================================
# Aliases - Git
# =============================================================================
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gp='git push'
alias gpl='git pull'
alias gl='git log --oneline --graph --decorate'
alias gla='git log --oneline --graph --decorate --all'
alias gd='git diff'
alias gds='git diff --staged'
alias gco='git checkout'
alias gb='git branch'
alias gba='git branch -a'
alias gcl='git clone'
alias gst='git stash'
alias gstp='git stash pop'

# Quick git operations
alias push='git add . && git commit -m "update" && git push'

# =============================================================================
# Aliases - Safety
# =============================================================================
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# =============================================================================
# Aliases - System
# =============================================================================
alias df='df -h'
alias du='du -h'
alias duh='du -h --max-depth=1 | sort -h'
alias free='free -h'
alias top='btop'

# =============================================================================
# Aliases - Docker/Podman
# =============================================================================
alias docker='podman'
alias dps='podman ps'
alias dpsa='podman ps -a'
alias dcu='podman-compose up'
alias dcd='podman-compose down'

# =============================================================================
# Aliases - Development
# =============================================================================
alias serve='python3 -m http.server'
alias jn='jupyter lab'
alias code='code'

# =============================================================================
# Aliases - Misc
# =============================================================================
alias c='clear'
alias h='history'
alias reload='source ~/.config/fish/config.fish'
alias ports='netstat -tulanp'
alias myip='curl -s ifconfig.me'

# =============================================================================
# Functions
# =============================================================================

# Create directory and cd into it
function mkcd
    mkdir -p $argv[1]; and cd $argv[1]
end

# Extract any archive
function extract
    if test -f $argv[1]
        switch $argv[1]
            case '*.tar.bz2'; tar xjf $argv[1]
            case '*.tar.gz'; tar xzf $argv[1]
            case '*.tar.xz'; tar xf $argv[1]
            case '*.tar.zst'; tar --zstd -xf $argv[1]
            case '*.bz2'; bunzip2 $argv[1]
            case '*.gz'; gunzip $argv[1]
            case '*.tar'; tar xf $argv[1]
            case '*.tbz2'; tar xjf $argv[1]
            case '*.tgz'; tar xzf $argv[1]
            case '*.zip'; unzip $argv[1]
            case '*.Z'; uncompress $argv[1]
            case '*.7z'; 7z x $argv[1]
            case '*.rar'; unrar x $argv[1]
            case '*.deb'; ar x $argv[1]
            case '*'; echo "'$argv[1]' cannot be extracted"
        end
    else
        echo "'$argv[1]' is not a valid file"
    end
end

# Quick find in current directory
function qfind
    fd -H $argv[1]
end

# Backup file with timestamp
function backup
    if test -f $argv[1]
        set timestamp (date +%Y%m%d_%H%M%S)
        cp $argv[1] "$argv[1].backup.$timestamp"
        echo "Backup created: $argv[1].backup.$timestamp"
    else
        echo "File not found: $argv[1]"
    end
end

# Quick git commit with message
function gcam
    git add --all; and git commit -m "$argv[1]"
end

# Poetry run wrapper - ensures venv activation
function prun
    if test -f pyproject.toml
        poetry run $argv
    else
        echo "No pyproject.toml found"
    end
end

# =============================================================================
# Tool Initialization
# =============================================================================

# Initialize Starship prompt
if command -v starship > /dev/null
    starship init fish | source
end

# Initialize zoxide (smart cd)
if command -v zoxide > /dev/null
    zoxide init fish | source
end

# Initialize pyenv
if command -v pyenv > /dev/null
    pyenv init - | source
end

# Initialize fzf
if command -v fzf > /dev/null
    # Key bindings
    fzf --fish | source 2>/dev/null
end

# =============================================================================
# Custom Greeting
# =============================================================================
function fish_greeting
    echo ""
    printf "\x1b[1;34m=== Arch Dev Container ===\x1b[0m\n"
    printf "User: %s | Host: %s\n" (whoami) (hostname)
    printf "Type 'exit' to return to Fedora host\n"
    echo ""
end
FISHCONFIG

# =============================================================================
# STARSHIP CONFIGURATION
# =============================================================================
echo "[2/4] Configuring Starship prompt..."

mkdir -p ~/.config

cat > ~/.config/starship.toml << 'STARSHIPCONFIG'
# Starship Prompt Configuration
# https://starship.rs/config/

format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$python\
$nodejs\
$rust\
$golang\
$docker_context\
$cmd_duration\
$line_break\
$character"""

[username]
show_always = true
style_user = "bold cyan"
style_root = "bold red"
format = "[$user]($style)@"

[hostname]
ssh_only = false
style = "bold green"
format = "[$hostname]($style) "

[directory]
style = "bold blue"
truncation_length = 3
truncate_to_repo = true
format = "[$path]($style)[$read_only]($read_only_style) "

[git_branch]
symbol = " "
style = "bold purple"
format = "[$symbol$branch]($style) "

[git_status]
style = "bold yellow"
format = '([\[$all_status$ahead_behind\]]($style) )'
conflicted = "="
ahead = "⇡${count}"
behind = "⇣${count}"
diverged = "⇕⇡${ahead_count}⇣${behind_count}"
untracked = "?"
stashed = "$"
modified = "!"
staged = "+"
renamed = "»"
deleted = "✘"

[python]
symbol = " "
style = "bold yellow"
format = '[${symbol}${pyenv_prefix}(${version})(\($virtualenv\))]($style) '
pyenv_version_name = true

[nodejs]
symbol = " "
style = "bold green"
format = "[$symbol($version)]($style) "

[rust]
symbol = " "
style = "bold red"
format = "[$symbol($version)]($style) "

[golang]
symbol = " "
style = "bold cyan"
format = "[$symbol($version)]($style) "

[docker_context]
symbol = " "
style = "bold blue"
format = "[$symbol$context]($style) "

[cmd_duration]
min_time = 2_000
style = "bold yellow"
format = "[$duration]($style) "

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
STARSHIPCONFIG

# =============================================================================
# ZSH CONFIGURATION (Alternative Shell)
# =============================================================================
echo "[3/4] Configuring Zsh..."

cat > ~/.zshrc << 'ZSHCONFIG'
### ------------------ ###
### --- ZSH CONFIG --- ###
### ------------------ ###

# =============================================================================
# PATH Configuration
# =============================================================================
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
export PATH="$HOME/.pyenv/bin:$PATH"

# =============================================================================
# Environment Variables
# =============================================================================
export EDITOR=nvim
export VISUAL=nvim
export PAGER="less -R"
export path_to_my_git="$HOME/Documents/Git/"

# Poetry config
export POETRY_VIRTUALENVS_IN_PROJECT=true

# Go
export GOPATH=$HOME/go

# =============================================================================
# Oh My Zsh (if installed)
# =============================================================================
if [ -d "$HOME/.oh-my-zsh" ]; then
    export ZSH="$HOME/.oh-my-zsh"
    ZSH_THEME=""  # Using Starship instead
    plugins=(git docker kubectl)
    source $ZSH/oh-my-zsh.sh
fi

# =============================================================================
# Aliases
# =============================================================================
# Python
alias py='python3'
alias python='python3'
alias pip='pip3'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Modern CLI
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first'
alias lt='eza -T --icons --level=2'
alias cat='bat --style=plain'
alias grep='rg'
alias find='fd'

# Git
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gp='git push'
alias gpl='git pull'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'
alias push='git add . && git commit -m "update" && git push'

# Safety
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# System
alias df='df -h'
alias du='du -h'
alias free='free -h'

# Docker/Podman
alias docker='podman'
alias dps='podman ps'
alias dpsa='podman ps -a'

# =============================================================================
# Functions
# =============================================================================
mkcd() { mkdir -p "$1" && cd "$1" }

extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    tar xzf "$1"     ;;
            *.tar.xz)    tar xf "$1"      ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.zip)       unzip "$1"       ;;
            *.7z)        7z x "$1"        ;;
            *)           echo "'$1' cannot be extracted" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# =============================================================================
# Tool Initialization
# =============================================================================
# Starship prompt
if command -v starship &> /dev/null; then
    eval "$(starship init zsh)"
fi

# Zoxide
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init zsh)"
fi

# Pyenv
if command -v pyenv &> /dev/null; then
    eval "$(pyenv init -)"
fi

# FZF
if command -v fzf &> /dev/null; then
    source <(fzf --zsh) 2>/dev/null
fi

echo "Zsh loaded successfully!"
ZSHCONFIG

# =============================================================================
# NEOVIM BASIC CONFIGURATION
# =============================================================================
echo "[4/4] Configuring Neovim..."

mkdir -p ~/.config/nvim

cat > ~/.config/nvim/init.lua << 'NVIMCONFIG'
-- Neovim Basic Configuration

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = true

-- Tabs and indentation
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.autoindent = true

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- Appearance
vim.opt.termguicolors = true
vim.opt.cursorline = true
vim.opt.signcolumn = "yes"

-- Split windows
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Clipboard (system clipboard integration)
vim.opt.clipboard = "unnamedplus"

-- Mouse support
vim.opt.mouse = "a"

-- Key mappings
vim.g.mapleader = " "

-- Quick save
vim.keymap.set('n', '<leader>w', ':w<CR>')

-- Quick quit
vim.keymap.set('n', '<leader>q', ':q<CR>')

-- Clear search highlight
vim.keymap.set('n', '<Esc>', ':noh<CR>')

-- Better window navigation
vim.keymap.set('n', '<C-h>', '<C-w>h')
vim.keymap.set('n', '<C-j>', '<C-w>j')
vim.keymap.set('n', '<C-k>', '<C-w>k')
vim.keymap.set('n', '<C-l>', '<C-w>l')
NVIMCONFIG

# =============================================================================
# SET DEFAULT SHELL
# =============================================================================
echo "Setting Fish as default shell in container..."

# Create distrobox entry command
mkdir -p ~/.config/distrobox
echo "fish" > ~/.config/distrobox/default_shell 2>/dev/null || true

# =============================================================================
# COMPLETION
# =============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     SHELL CONFIGURATION COMPLETE                               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Configured:"
echo "  - Fish shell (~/.config/fish/config.fish)"
echo "  - Starship prompt (~/.config/starship.toml)"
echo "  - Zsh shell (~/.zshrc)"
echo "  - Neovim (~/.config/nvim/init.lua)"
echo ""
echo "Modern CLI tools aliased:"
echo "  - ls  → eza"
echo "  - cat → bat"
echo "  - grep → rg (ripgrep)"
echo "  - find → fd"
echo "  - diff → delta"
echo "  - cd   → zoxide (after some usage)"
echo ""
echo "To apply changes:"
echo "  Fish: source ~/.config/fish/config.fish"
echo "  Zsh:  source ~/.zshrc"
echo ""
echo "Next: Run ./07-install-vscode-extensions.sh"
