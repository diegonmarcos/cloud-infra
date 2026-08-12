#!/bin/sh
# Workflow generation — delegates to 9_others/build.sh
# That engine owns the src/ → dist/ → .github/ pipeline
set -e
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
exec "$CLOUD_ROOT/9_others/build.sh" "$@"
