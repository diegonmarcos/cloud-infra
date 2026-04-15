#!/bin/sh
# Workflow generation — delegates to 1_workflows/build.sh
# That engine owns the src/ → dist/ → .github/ pipeline
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
exec "$CLOUD_ROOT/1_workflows/build.sh" "$@"
