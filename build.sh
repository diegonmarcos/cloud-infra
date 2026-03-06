#!/bin/sh
# Container-Nix Orchestrator
# Delegates builds to per-service build.sh, deploys dist/ to VMs
# Configuration: cloud-topology.json
set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOLUTIONS_DIR="$SCRIPT_DIR/a_solutions"
CONFIG_FILE="$SCRIPT_DIR/cloud-topology.json"
# Fallback to old name during migration
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="$SCRIPT_DIR/config.json"

# =============================================================================
# Dependency Engine
# =============================================================================

REQUIRED_SYSTEM="node git ssh jq sops"
REQUIRED_NODE="tsx yaml nunjucks"

check_deps() {
    missing_sys=""
    missing_node=""

    for tool in $REQUIRED_SYSTEM; do
        command -v "$tool" >/dev/null 2>&1 || missing_sys="$missing_sys $tool"
    done

    if command -v node >/dev/null 2>&1; then
        engine_dir="$SOLUTIONS_DIR/mcp-api-c3/src"
        for pkg in $REQUIRED_NODE; do
            NODE_PATH="$engine_dir/node_modules" node -e "require('$pkg')" 2>/dev/null \
                || missing_node="$missing_node $pkg"
        done
    fi

    [ -z "$missing_sys" ] && [ -z "$missing_node" ] && return 0

    echo ""
    echo "============================================"
    echo "  MISSING DEPENDENCIES"
    echo "============================================"
    [ -n "$missing_sys" ]  && echo "  System:  $missing_sys"
    [ -n "$missing_node" ] && echo "  Node:    $missing_node"
    echo ""

    if command -v nix-env >/dev/null 2>&1; then
        sys_cmd="nix-env -iA$(echo "$missing_sys" | sed 's/ / nixpkgs./g; s/^/ nixpkgs./')"
    elif command -v apt-get >/dev/null 2>&1; then
        sys_cmd="sudo apt-get install -y$missing_sys"
    else
        echo "  No supported package manager (nix/apt). Install manually:"
        echo "   $missing_sys $missing_node"
        exit 1
    fi

    node_cmd=""
    [ -n "$missing_node" ] && node_cmd="(cd $SOLUTIONS_DIR/mcp-api-c3/src && npm install)"

    printf "  Install all missing deps? [y/N] "
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        [ -n "$missing_sys" ] && eval "$sys_cmd"
        [ -n "$node_cmd" ] && eval "$node_cmd"
        check_deps  # re-verify
    else
        echo "  Aborting. Install manually:"
        [ -n "$missing_sys" ] && echo "    $sys_cmd"
        [ -n "$node_cmd" ]   && echo "    $node_cmd"
        exit 1
    fi
}

# Check deps at startup
check_deps

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

# SSH key - auto-detect
if [ -f "$HOME/.ssh/id_rsa" ]; then
    SSH_KEY="$HOME/.ssh/id_rsa"
elif [ -f "$HOME/git/vault/A0_keys/ssh/id_rsa" ]; then
    SSH_KEY="$HOME/git/vault/A0_keys/ssh/id_rsa"
else
    SSH_KEY=$(jq -r '.ssh_key // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

# SSH config for GCP proxy (mobile)
if [ -f "$HOME/git/vault/A0_keys/config_mobile" ]; then
    SSH_CONFIG="$HOME/git/vault/A0_keys/config_mobile"
fi

# =============================================================================
# Helpers
# =============================================================================

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
log_error() { printf "[%s] ERROR: %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

get_vm_prop() { jq -r ".vms[\"$1\"].$2 // empty" "$CONFIG_FILE"; }
get_svc_prop() { jq -r ".services[\"$1\"].$2 // empty" "$CONFIG_FILE"; }
get_all_vms() { jq -r '.vms | keys[]' "$CONFIG_FILE"; }
get_all_services() { jq -r '.services | keys[]' "$CONFIG_FILE"; }

# Map service name → folder name
get_service_folder() {
    service="$1"
    category=$(get_svc_prop "$service" "category")
    flake=$(get_svc_prop "$service" "flake")
    base_name="${flake:-$service}"
    case "$category" in
        app)    echo "aa-sui_${base_name}" ;;
        tools)  echo "bc-obs_${base_name}" ;;
        sec)    echo "bb-sec_${base_name}" ;;
        cloud)  echo "ba-clo_${base_name}" ;;
        data)   echo "ca-dat_${base_name}" ;;
        mic)    echo "ab-mic_${base_name}" ;;
        *)      echo "$base_name" ;;
    esac
}

# SSH into a VM (auto-detect method)
ssh_cmd() {
    vm_name="$1"; shift; cmd="$*"
    method=$(get_vm_prop "$vm_name" "method")
    ip=$(get_vm_prop "$vm_name" "ip")
    user=$(get_vm_prop "$vm_name" "user")

    if [ "$method" = "gcloud" ]; then
        if [ -n "$SSH_CONFIG" ]; then
            # Mobile: use proxy config
            if [ -n "$cmd" ]; then
                ssh -F "$SSH_CONFIG" gcp-proxy "$cmd"
            else
                ssh -F "$SSH_CONFIG" gcp-proxy
            fi
        else
            instance=$(get_vm_prop "$vm_name" "gcloud_instance")
            zone=$(get_vm_prop "$vm_name" "gcloud_zone")
            if [ -n "$cmd" ]; then
                gcloud compute ssh "$user@$instance" --zone "$zone" --command "$cmd"
            else
                gcloud compute ssh "$user@$instance" --zone "$zone"
            fi
        fi
    else
        if [ -n "$cmd" ]; then
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd"
        else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$user@$ip"
        fi
    fi
}

# Deploy dist/ to VM via rclone (SFTP) or rsync
deploy_to_vm() {
    vm_name="$1"; src="$2"; dest="$3"
    method=$(get_vm_prop "$vm_name" "method")
    ip=$(get_vm_prop "$vm_name" "ip")
    user=$(get_vm_prop "$vm_name" "user")

    if [ "$method" = "gcloud" ] && [ -n "$SSH_CONFIG" ]; then
        # Mobile GCP: use rclone with SSH proxy
        rclone copy "$src" ":sftp:$dest/" \
            --sftp-host="$ip" --sftp-user="$user" \
            --sftp-key-file="$SSH_KEY" \
            --sftp-known-hosts-file="$HOME/.ssh/known_hosts" \
            --transfers=4
    elif cmd_exists rsync; then
        rsync -avz --delete \
            -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
            "$src" "$user@$ip:$dest"
    elif cmd_exists rclone; then
        rclone copy "$src" ":sftp:$dest/" \
            --sftp-host="$ip" --sftp-user="$user" \
            --sftp-key-file="$SSH_KEY" \
            --sftp-known-hosts-file="$HOME/.ssh/known_hosts" \
            --transfers=4
    else
        log_error "No rsync or rclone available for deployment"
        return 1
    fi
}

# =============================================================================
# Commands
# =============================================================================

# Build one or all services (delegates to per-service build.sh)
cmd_build() {
    service="$1"
    ok=0; fail=0; skip=0

    if [ -n "$service" ]; then
        # Build single service
        build_service "$service"
    else
        # Build all services
        log "Building all services..."
        echo ""
        get_all_services | while read -r svc; do
            build_service "$svc" || true
        done
    fi
}

build_service() {
    svc="$1"
    folder=$(get_service_folder "$svc")
    svc_dir="$SOLUTIONS_DIR/$folder"

    # Skip services without a build.sh
    if [ ! -f "$svc_dir/build.sh" ]; then
        log "SKIP $svc (no build.sh)"
        return 0
    fi

    # Skip local-only (terraform)
    vm=$(get_svc_prop "$svc" "vm")
    if [ "$vm" = "local" ]; then
        log "SKIP $svc (local/terraform)"
        return 0
    fi

    log "Building $svc..."
    if sh "$svc_dir/build.sh" all 2>&1; then
        log "OK $svc"
    else
        log_error "FAIL $svc"
        return 1
    fi
    echo ""
}

# Ship (build + deploy) one or all services
cmd_ship() {
    service="$1"
    remote_base=$(jq -r '.remote_base' "$CONFIG_FILE")

    if [ -n "$service" ]; then
        deploy_service "$service" "$remote_base"
    else
        log "Deploying all services..."
        get_all_services | while read -r svc; do
            deploy_service "$svc" "$remote_base" || true
        done
    fi
}

deploy_service() {
    svc="$1"; remote_base="$2"
    folder=$(get_service_folder "$svc")
    svc_dir="$SOLUTIONS_DIR/$folder"
    dist_dir="$svc_dir/dist"

    vm=$(get_svc_prop "$svc" "vm")
    [ "$vm" = "local" ] && return 0
    [ "$vm" = "all" ] && return 0

    # Build first if dist/ doesn't exist
    if [ ! -d "$dist_dir" ]; then
        build_service "$svc" || return 1
    fi

    if [ ! -d "$dist_dir" ]; then
        log "SKIP $svc (no dist/ after build)"
        return 0
    fi

    remote_path="$remote_base/$svc"
    log "Deploying $svc -> $vm:$remote_path"

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] Would sync $dist_dir/ to $vm:$remote_path/"
        return 0
    fi

    # Create remote dir
    ssh_cmd "$vm" "sudo mkdir -p $remote_path && sudo chown \$(whoami):\$(whoami) $remote_path"

    # Sync dist/ to VM
    deploy_to_vm "$vm" "$dist_dir/" "$remote_path/"
    log "Deployed $svc to $vm:$remote_path/"
}

# Compose up on VM
cmd_compose() {
    service="$1"
    remote_base=$(jq -r '.remote_base' "$CONFIG_FILE")

    if [ -n "$service" ]; then
        vm=$(get_svc_prop "$service" "vm")
        remote_path="$remote_base/$service"
        log "docker compose up on $vm:$remote_path"
        ssh_cmd "$vm" "cd $remote_path && docker compose down 2>/dev/null; docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d"
    else
        log_error "Service name required for compose"
        exit 1
    fi
}

# SSH into VM
cmd_ssh() {
    vm_name="$1"
    [ -z "$vm_name" ] && { log_error "VM name required"; get_all_vms | sed 's/^/  /'; exit 1; }
    log "Connecting to $vm_name..."
    ssh_cmd "$vm_name"
}

# Docker status on VM
cmd_status() {
    vm_name="$1"
    [ -z "$vm_name" ] && { log_error "VM name required"; exit 1; }
    log "Docker status on $vm_name:"
    ssh_cmd "$vm_name" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
}

# Restart service on VM
cmd_restart() {
    service="$1"
    [ -z "$service" ] && { log_error "Service name required"; exit 1; }
    vm=$(get_svc_prop "$service" "vm")
    remote_base=$(jq -r '.remote_base' "$CONFIG_FILE")
    log "Restarting $service on $vm..."
    ssh_cmd "$vm" "cd $remote_base/$service && docker compose down && docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d"
    log "Restarted $service"
}

# Secrets management
cmd_secrets() {
    service="$1"; action="$2"

    if [ -z "$service" ]; then
        echo ""
        echo "=== Secrets Status ==="
        printf "  %-25s %-12s %s\n" "SERVICE" "STATUS" "FILE"
        printf "  %s\n" "------------------------------------------------------------"
        for folder in "$SOLUTIONS_DIR"/*/src/secrets.yaml; do
            [ -f "$folder" ] || continue
            svc_name=$(basename "$(dirname "$(dirname "$folder")")")
            if grep -q "sops:" "$folder" 2>/dev/null; then
                status="encrypted"
            else
                status="PLAINTEXT"
            fi
            printf "  %-25s %-12s %s\n" "$svc_name" "$status" "src/secrets.yaml"
        done
        echo ""
        return
    fi

    folder=$(get_service_folder "$service")
    secrets_file="$SOLUTIONS_DIR/$folder/src/secrets.yaml"
    [ ! -f "$secrets_file" ] && { log_error "No secrets.yaml for $service"; exit 1; }

    case "$action" in
        encrypt) sops -e -i "$secrets_file"; log "Encrypted $secrets_file" ;;
        decrypt) sh "$SOLUTIONS_DIR/$folder/build.sh" secrets; log "Decrypted to dist/.secrets" ;;
        edit)    sops "$secrets_file" ;;
        show)    sops -d "$secrets_file" ;;
        *)       sops -d "$secrets_file" 2>/dev/null | grep -v "^#" | grep -v "^$" | cut -d: -f1 | sed 's/^/  /' ;;
    esac
}

# Generate cloud-topology.json/md + cloud-configs.json/md from sources
cmd_config() {
    ENGINE_DIR="$SOLUTIONS_DIR/mcp-api-c3/src"
    if [ ! -d "$ENGINE_DIR/node_modules" ]; then
        log "Installing engine dependencies..."
        (cd "$ENGINE_DIR" && npm install --silent)
    fi
    TSX="$ENGINE_DIR/node_modules/.bin/tsx"
    log "Generating cloud-topology.json + cloud-topology.md..."
    "$TSX" "$ENGINE_DIR/engines/gen-topology.ts"
    log "Generating cloud-configs.json + cloud-configs.md..."
    "$TSX" "$ENGINE_DIR/engines/gen-configs.ts"
}

# Clean all dist/ folders
cmd_clean() {
    log "Cleaning all dist/ folders..."
    count=0
    for d in "$SOLUTIONS_DIR"/*/dist; do
        [ -d "$d" ] || continue
        rm -rf "$d"
        count=$((count + 1))
    done
    # Also clean .result symlinks
    for r in "$SOLUTIONS_DIR"/*/.result; do
        [ -e "$r" ] && rm -f "$r"
    done
    log "Cleaned $count dist/ folders"
}

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat <<'EOF'
Cloud Orchestrator — repo-level CLI for cloud/ infrastructure

USAGE:  ./build.sh <command> [args]

PIPELINE:
    build [service]       Nix build -> dist/ (all services if omitted)
    ship [service]        Full pipeline: build + secrets + deploy + compose
    compose <service>     Docker compose up on target VM
    clean                 Remove all dist/ folders

CONFIG:
    config                Regenerate cloud-topology + cloud-configs from sources
                          (parses SSH config, build.json, Caddyfile, Authelia, DNS, etc.)

OPS:
    ssh <alias>           SSH into a VM (e.g. oci-apps, gcp-proxy)
    status <alias>        Docker container status on a VM
    restart <service>     Restart service (compose down + up on VM)

SECRETS:
    secrets               List all services with secrets status
    secrets <s> show      Show decrypted secrets
    secrets <s> edit      Edit encrypted secrets (opens $EDITOR)
    secrets <s> encrypt   Encrypt plaintext secrets.yaml
    secrets <s> decrypt   Decrypt to dist/.secrets

OPTIONS:
    -n, --dry-run         Show what would be done (no changes)
    -v, --verbose         Enable verbose output (set -x)
    -k, --key <path>      Override SOPS age key path

EXAMPLES:
    ./build.sh ship authelia        Build + deploy + compose authelia
    ./build.sh build lgtm           Build single service to dist/
    ./build.sh build                Build all services
    ./build.sh compose lgtm         Compose up on target VM
    ./build.sh config               Regenerate config from sources
    ./build.sh ssh oci-apps         SSH into oci-apps VM
    ./build.sh status gcp-proxy     Check containers on gcp-proxy
    ./build.sh secrets authelia     List secret keys for authelia
EOF
    exit 0
}

# =============================================================================
# Main
# =============================================================================

DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -v|--verbose) set -x; shift ;;
        -k|--key)     SOPS_AGE_KEY_FILE="$2"; export SOPS_AGE_KEY_FILE; shift 2 ;;
        -h|--help)    usage ;;
        -*)           log_error "Unknown option: $1"; exit 1 ;;
        *)            break ;;
    esac
done

command="${1:-}"; shift 2>/dev/null || true

case "$command" in
    build)    cmd_build "$@" ;;
    ship)     cmd_ship "$@" ;;
    compose)  cmd_compose "$@" ;;
    clean)    cmd_clean ;;
    ssh)      cmd_ssh "$@" ;;
    status)   cmd_status "$@" ;;
    restart)  cmd_restart "$@" ;;
    secrets)  cmd_secrets "$@" ;;
    config)   cmd_config ;;
    ""|help)  usage ;;
    *)        log_error "Unknown: $command"; usage ;;
esac
