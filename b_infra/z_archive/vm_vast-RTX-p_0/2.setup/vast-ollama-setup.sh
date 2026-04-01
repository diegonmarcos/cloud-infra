#!/usr/bin/env bash
# Vast.ai Ollama Setup Script
# Automates Ollama installation and model deployment on Vast.ai instances

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*"; }

# Check if we're on Vast.ai instance
check_vast_instance() {
    if ! command -v nvidia-smi &> /dev/null; then
        log_error "nvidia-smi not found - are you on a GPU instance?"
        return 1
    fi

    log_info "Checking GPU..."
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    log_success "GPU detected"
}

# Install Ollama
install_ollama() {
    if command -v ollama &> /dev/null; then
        log_success "Ollama already installed: $(ollama --version)"
        return 0
    fi

    log_info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    log_success "Ollama installed: $(ollama --version)"
}

# Start Ollama service
start_ollama_service() {
    log_info "Starting Ollama service..."

    # Kill existing ollama processes
    pkill ollama 2>/dev/null || true

    # Start ollama in background with API accessible
    OLLAMA_HOST=0.0.0.0:11434 ollama serve > /var/log/ollama.log 2>&1 &
    OLLAMA_PID=$!

    sleep 3

    if ps -p $OLLAMA_PID > /dev/null; then
        log_success "Ollama service started (PID: $OLLAMA_PID)"
        echo $OLLAMA_PID > /tmp/ollama.pid
    else
        log_error "Failed to start Ollama service"
        return 1
    fi
}

# Pull models
pull_models() {
    local models=(
        "llama2:13b"
        "mistral:13b"
        "deepseek-r1:14b"
    )

    log_info "Available models to pull:"
    for i in "${!models[@]}"; do
        echo "  $((i+1)). ${models[$i]}"
    done

    read -p "Select model(s) to pull (1-3, comma-separated, or 'all'): " selection

    if [[ "$selection" == "all" ]]; then
        for model in "${models[@]}"; do
            log_info "Pulling $model..."
            ollama pull "$model"
            log_success "$model downloaded"
        done
    else
        IFS=',' read -ra INDICES <<< "$selection"
        for idx in "${INDICES[@]}"; do
            idx=$((idx - 1))
            if [[ $idx -ge 0 && $idx -lt ${#models[@]} ]]; then
                model="${models[$idx]}"
                log_info "Pulling $model..."
                ollama pull "$model"
                log_success "$model downloaded"
            fi
        done
    fi
}

# Show usage info
show_usage() {
    cat << EOF

${GREEN}═══════════════════════════════════════════════════════════════${NC}
${GREEN}  Ollama Setup Complete!${NC}
${GREEN}═══════════════════════════════════════════════════════════════${NC}

${BLUE}API Access:${NC}
  Ollama is running at: http://0.0.0.0:11434

  From your local machine:
    curl http://<vast-ip>:11434/api/generate -d '{
      "model": "llama2:13b",
      "prompt": "Hello!",
      "stream": false
    }'

${BLUE}Interactive Chat:${NC}
  ollama run llama2:13b
  ollama run mistral:13b
  ollama run deepseek-r1:14b

${BLUE}Management:${NC}
  ollama list                    # List installed models
  ollama pull <model>            # Download a model
  ollama rm <model>              # Remove a model
  ollama ps                      # List running models

${BLUE}Service Control:${NC}
  pkill ollama                   # Stop service
  OLLAMA_HOST=0.0.0.0:11434 ollama serve &  # Start service

${BLUE}Logs:${NC}
  tail -f /var/log/ollama.log

${BLUE}Cost Reminder:${NC}
  You're charged ${YELLOW}\$0.08-0.25/hour${NC} while instance is running
  Stop instance when done: https://vast.ai/console/instances/

${GREEN}═══════════════════════════════════════════════════════════════${NC}

EOF
}

# Main setup flow
main() {
    echo -e "${BLUE}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   Vast.ai Ollama Setup                                       ║
║   LLM Server for 13B Models (RTX A4000 16GB VRAM)            ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    check_vast_instance
    install_ollama
    start_ollama_service

    read -p "Pull models now? (y/n): " pull_now
    if [[ "$pull_now" =~ ^[Yy]$ ]]; then
        pull_models
    else
        log_info "Skipping model download. Pull models later with: ollama pull <model-name>"
    fi

    show_usage
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
