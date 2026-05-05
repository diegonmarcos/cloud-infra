# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-ship-lib.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# cloud-ship-lib.sh — Shared library for cloud-ship scripts
# Sourced, not executed directly. No shebang.

CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)}"

# =============================================================================
# Configuration
# =============================================================================

SOLUTIONS_DIR="$CLOUD_ROOT/a_solutions"
# 2026-04-27 migrated: cloud-data-topology.json -> _cloud-data-consolidated.json
# Consolidated is a superset of topology (same .services / .vms keys).
CONFIG_FILE=""
for _p in \
    "/app/_cloud-data-consolidated.json" \
    "$CLOUD_ROOT/2_configs/dist/_cloud-data-consolidated.json" \
    "$CLOUD_ROOT/cloud-data/_cloud-data-consolidated.json" \
    "$CLOUD_ROOT/_cloud-data-consolidated.json" \
    "/app/cloud-data-topology.json" \
    "$CLOUD_ROOT/2_configs/dist/cloud-data-topology.json" \
    "$CLOUD_ROOT/2_configs/dist/z_archive/cloud-data-topology.json" \
    "$CLOUD_ROOT/cloud-data/cloud-data-topology.json" \
    "$CLOUD_ROOT/cloud-data-topology.json"; do
    [ -f "$_p" ] && { CONFIG_FILE="$_p"; break; }
done

# Shared node_modules — ESM (tsx) does not respect NODE_PATH, but CJS fallback does.
# Set here so all tsx calls in this script find packages from the shared install.
export NODE_PATH="${NODE_PATH:-$HOME/.node_modules/node_modules}"
export BUILDSH_GUARDRAIL=1
# Fallback to old name during migration
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="$CLOUD_ROOT/config.json"
ENGINE_FOLDER=$(jq -r ".engine_folder" "$CLOUD_ROOT/config.json" 2>/dev/null)
ENGINE_DIR="$SOLUTIONS_DIR/$ENGINE_FOLDER/src"
ENGINES_DIR="$ENGINE_DIR/shared/engines"
export PATH="$ENGINE_DIR/node_modules/.bin:$PATH"

# =============================================================================
# Dependency Engine — reads from config.json .deps section
# =============================================================================

# Settings from config.json deps.install section
DEPS_NIX_METHOD=$(jq -r '.deps.install.nix_method // "shell"' "$CONFIG_FILE")
DEPS_AUTO_YES=$(jq -r '.deps.install.auto_yes // false' "$CONFIG_FILE")

# Also auto-yes when non-interactive (CI, piped, GHA)
[ ! -t 0 ] && DEPS_AUTO_YES=true
[ -n "${CI:-}" ] && DEPS_AUTO_YES=true
[ -n "${GITHUB_ACTIONS:-}" ] && DEPS_AUTO_YES=true

# Detect package manager: nix > apt > none
detect_pm() {
    if command -v nix >/dev/null 2>&1; then
        echo "nix"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    else
        echo "none"
    fi
}

# Deps read from config.json (source of truth), NOT from topology
DEPS_FILE="$CLOUD_ROOT/config.json"
deps_binaries() { jq -r '.deps.system | keys[]' "$DEPS_FILE" | tr '\n' ' '; }
deps_pkg_name() { jq -r ".deps.system[\"$1\"][\"$2\"] // empty" "$DEPS_FILE"; }
deps_node_required() { jq -r '.deps.node.required[]' "$DEPS_FILE" | tr '\n' ' '; }

# Confirm prompt — auto-yes if configured or non-interactive
confirm() {
    [ "$DEPS_AUTO_YES" = "true" ] && return 0
    printf "  %s [y/N] " "$1"
    read -r answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# Install nix packages — ephemeral (shell-style), never via `nix profile install`.
# The profile branch was removed 2026-05-05: zero consumers ever set
# DEPS_NIX_METHOD=profile (default was always "shell"), and `nix profile install`
# violates the "no host-state mutation" rule that applies to every other path
# in this engine. If you need persistence, declare the dep in a flake.
nix_install() {
    log "Nix (shell): adding $*"
    for pkg in $*; do
        pkg_path=$(nix build --no-link --print-out-paths "$pkg" 2>/dev/null) || continue
        export PATH="$pkg_path/bin:$PATH"
    done
}

# Check what's missing — prints status, returns 1 if anything missing
check_deps() {
    missing_sys=""
    missing_node=""

    for bin in $(deps_binaries); do
        # sudo not needed when running as root (GHA builders, containers)
        [ "$bin" = "sudo" ] && [ "$(id -u)" = "0" ] && continue
        command -v "$bin" >/dev/null 2>&1 || missing_sys="$missing_sys $bin"
    done

    if command -v node >/dev/null 2>&1; then
        engine_dir="$ENGINE_DIR"
        for pkg in $(deps_node_required); do
            NODE_PATH="$engine_dir/node_modules:${NODE_PATH:-}" node -e "require('$pkg')" 2>/dev/null \
                || missing_node="$missing_node $pkg"
        done
    fi

    [ -z "$missing_sys" ] && [ -z "$missing_node" ] && return 0

    log "WARNING: Missing deps:${missing_sys}${missing_node:+ (node:$missing_node)} — some commands may fail. Run: ./build.sh deps"
    return 0
}

# =============================================================================
# SSH / Secrets / Helpers
# =============================================================================

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
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
# Defaults
# =============================================================================

DRY_RUN="${DRY_RUN:-0}"
