#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Cloud Orchestrator — pure dispatcher                            ║
# ║                                                                  ║
# ║ Zero logic here. All commands delegate to scripts in             ║
# ║ 1_workflows/src/scripts/cloud-ship-*.sh                         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

CLOUD_ROOT="$(cd "$(dirname "$0")" && pwd)"
export CLOUD_ROOT
SCRIPTS="$CLOUD_ROOT/1_workflows/src/scripts"

# Source shared library (config, helpers, deps check)
. "$SCRIPTS/cloud-ship-lib.sh"

# ── Parse global flags ─────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) export DRY_RUN=1; shift ;;
        -v|--verbose) set -x; shift ;;
        -k|--key)     SOPS_AGE_KEY_FILE="$2"; export SOPS_AGE_KEY_FILE; shift 2 ;;
        -h|--help)    command="help"; shift ;;
        -*)           log_error "Unknown option: $1"; exit 1 ;;
        *)            break ;;
    esac
done

command="${1:-}"; shift 2>/dev/null || true

# Check deps at startup (skip for 'deps' command)
[ "$command" != "deps" ] && check_deps

# ── Dispatch ───────────────────────────────────────────────────────
case "$command" in
    deps)         sh "$SCRIPTS/cloud-ship-repo-deps.sh" "$@" ;;
    build)        sh "$SCRIPTS/cloud-ship-orchestrate-build.sh" "$@" ;;
    ship)         sh "$SCRIPTS/cloud-ship-orchestrate-ship.sh" "$@" ;;
    compose)      sh "$SCRIPTS/cloud-ship-repo-compose.sh" "$@" ;;
    ssh)          sh "$SCRIPTS/cloud-ship-repo-ssh.sh" "$@" ;;
    status)       sh "$SCRIPTS/cloud-ship-repo-status.sh" "$@" ;;
    restart)      sh "$SCRIPTS/cloud-ship-repo-restart.sh" "$@" ;;
    secrets)      sh "$SCRIPTS/cloud-ship-repo-secrets.sh" "$@" ;;
    config)       sh "$SCRIPTS/cloud-ship-repo-config-gen.sh" ;;
    workflow)     sh "$SCRIPTS/cloud-ship-repo-workflow-gen.sh" ;;
    clean)        sh "$SCRIPTS/cloud-ship-repo-clean.sh" ;;
    profile-ship) sh "$SCRIPTS/cloud-ship-orchestrate-profile.sh" "$@" ;;
    ""|help)
        cat <<'EOF'
Cloud Orchestrator — repo-level CLI for cloud/ infrastructure

USAGE:  ./build.sh <command> [args]

SETUP:
    deps                  Install ALL dependencies from config.json (nix + node)

PIPELINE:
    build [service]       Nix build -> dist/ (all services if omitted)
    ship [service]        Full pipeline: build + secrets + deploy + compose
    compose <service>     Docker compose up on target VM
    clean                 Remove all dist/ folders

CONFIG:
    config                Regenerate cloud-topology + cloud-configs from sources
    workflow              Generate GHA workflows from build.json + templates

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
    ./build.sh config               Regenerate config from sources
    ./build.sh ssh oci-apps         SSH into oci-apps VM
    ./build.sh secrets authelia     List secret keys for authelia
EOF
        exit 0
        ;;
    *)  log_error "Unknown: $command"; exit 1 ;;
esac
