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
bash "$SCRIPTS/cloud-builder-secrets.sh"

# ── Dispatch ─────────────────────────────────────────────────────
CMD="${1:?Usage: cloud-builder.sh <command> [args...]}"
shift
case "$CMD" in
  ship) exec bash "$SCRIPTS/cloud-builder-ship.sh" "$@" ;;
  *)    echo "Unknown: $CMD (available: ship)" >&2; exit 1 ;;
esac
