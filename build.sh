#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Cloud Orchestrator — pure dispatcher                            ║
# ║                                                                  ║
# ║ Zero logic here. All commands delegate to scripts in             ║
# ║ 1_configs/src/deploy/scripts/cloud-ship-*.sh                         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

CLOUD_ROOT="$(cd "$(dirname "$0")" && pwd)"
export CLOUD_ROOT
SCRIPTS="$CLOUD_ROOT/1_configs/src/deploy/scripts"

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
    # ── PIPELINE ──
    ship)              sh "$SCRIPTS/cloud-ship-orchestrate-ship.sh" "$@" ;;
    ship-hm)           sh "$SCRIPTS/cloud-ship-orchestrate-homemanager.sh" "$@" ;;
    ship-terraform)    sh "$SCRIPTS/cloud-ship-terraform-deploy-apply.sh" "$@" ;;
    ship-all)          sh "$SCRIPTS/cloud-ship-orchestrate-ship.sh" "$@" && sh "$SCRIPTS/cloud-ship-orchestrate-homemanager.sh" "$@" ;;
    # ── BUILD ──
    build)             sh "$SCRIPTS/cloud-ship-orchestrate-build.sh" "$@" ;;
    compose)           sh "$SCRIPTS/cloud-ship-repo-compose.sh" "$@" ;;
    # ── CONFIG ──
    config)            sh "$SCRIPTS/cloud-ship-repo-config-gen.sh" ;;
    workflow)          sh "$SCRIPTS/cloud-ship-repo-workflow-gen.sh" ;;
    secrets)           sh "$SCRIPTS/cloud-ship-repo-secrets.sh" "$@" ;;
    # ── CICD (inside cloud-builder container) ──
    cicd-ship)         sh "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" ship "$@" ;;
    cicd-ship-hm)      sh "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" ship-hm "$@" ;;
    cicd-terraform)    sh "$SCRIPTS/cloud-ship-terraform-deploy-apply.sh" "$@" ;;
    cicd-health)       sh "$SCRIPTS/cloud-health-full.sh" "$@" ;;
    cicd-gen-configs)  sh "$SCRIPTS/cloud-ship-orchestrate-gen-configs.sh" "$@" ;;
    # ── OPS ──
    ssh)               sh "$SCRIPTS/cloud-ship-repo-ssh.sh" "$@" ;;
    status)            sh "$SCRIPTS/cloud-ship-repo-status.sh" "$@" ;;
    restart)           sh "$SCRIPTS/cloud-ship-repo-restart.sh" "$@" ;;
    health)            sh "$SCRIPTS/cloud-health-full.sh" "$@" ;;
    clean)             sh "$SCRIPTS/cloud-ship-repo-clean.sh" ;;
    deps)              sh "$SCRIPTS/cloud-ship-repo-deps.sh" "$@" ;;
    profile-ship)      sh "$SCRIPTS/cloud-ship-orchestrate-profile.sh" "$@" ;;
    ""|help)
        cat <<'EOF'
Cloud Orchestrator — repo-level CLI for cloud/ infrastructure

USAGE:  ./build.sh <command> [args]

PIPELINE:
    ship [service|vm]          Ship containers (build + secrets + deploy + compose)
    ship-hm [vm|all]           Ship home-manager config to VM(s)
    ship-terraform [project]   Ship terraform (cloudflare, gcloud, oci, hetzner)
    ship-all [vm|all]          Ship containers + home-manager

BUILD:
    build [service]            Nix build → dist/
    compose <service>          Docker compose up --no-build on VM

CONFIG:
    config                     Generate cloud-data configs from sources
    workflow                   Generate GHA workflows from templates
    secrets [svc] [action]     Manage sops secrets (show|edit|encrypt|decrypt)

CICD (inside cloud-builder container):
    cicd-ship [vm|all]         Orchestrate container ship
    cicd-ship-hm [vm|all]     Orchestrate home-manager ship
    cicd-terraform [project]   Orchestrate terraform apply
    cicd-health                Orchestrate health checks
    cicd-gen-configs           Orchestrate config generation

OPS:
    ssh <alias>                SSH into VM
    status <alias>             Container status on VM
    restart <service>          Restart service on VM
    health                     Run health checks
    clean                      Remove all dist/
    deps                       Install dependencies from config.json

OPTIONS:
    -n, --dry-run              Show what would be done
    -v, --verbose              Enable verbose output
    -k, --key <path>           Override SOPS age key path

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
