#!/bin/bash
# vm-pilot — build + push delivery capsule image
# Usage: build.sh [build|docker|push|ship]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="$SCRIPT_DIR/build.json"
IMAGE=$(node -e "console.log(require('$CONFIG').docker.image)" 2>/dev/null \
     || python3 -c "import json; print(json.load(open('$CONFIG'))['docker']['image'])")

step_build() {
  echo "[vm-pilot] Copying src/ → dist/"
  rm -rf dist
  mkdir -p dist
  cp -rL src/modules dist/modules
  cp src/Dockerfile dist/Dockerfile
  echo "[vm-pilot] Done."
}

step_docker() {
  echo "[vm-pilot] Building $IMAGE:latest"
  docker build -t "$IMAGE:latest" dist/
  echo "[vm-pilot] Built: $IMAGE:latest"
}

step_push() {
  echo "[vm-pilot] Pushing $IMAGE:latest"
  docker push "$IMAGE:latest"
  echo "[vm-pilot] Pushed: $IMAGE:latest"
}

case "${1:-build}" in
  build)  step_build ;;
  docker) step_build && step_docker ;;
  push)   step_push ;;
  ship)   step_build && step_docker && step_push ;;
  *)      echo "Usage: build.sh [build|docker|push|ship]" ;;
esac
