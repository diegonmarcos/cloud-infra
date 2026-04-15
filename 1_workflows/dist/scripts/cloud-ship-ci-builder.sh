#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder.sh — CI/CD Orchestrator                           ║
# ║                                                                  ║
# ║ Runs inside ghcr.io/diegonmarcos/cloud-builder container.        ║
# ║ Repo already cloned at CWD. Sets up secrets, then dispatches.    ║
# ║                                                                  ║
# ║ Usage: cloud-builder.sh <command> [args...]                      ║
# ║   cloud-builder.sh ship gcp-proxy                                ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPTS=".github/workflows/scripts"

# ── Secrets ──────────────────────────────────────────────────────
bash "$SCRIPTS/cloud-ship-ci-builder-secrets.sh"

# ── Dispatch ─────────────────────────────────────────────────────
CMD="${1:?Usage: cloud-builder.sh <command> [args...]}"
shift
case "$CMD" in
  ship) exec bash "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" "$@" ;;
  *)    echo "Unknown: $CMD (available: ship)" >&2; exit 1 ;;
esac
