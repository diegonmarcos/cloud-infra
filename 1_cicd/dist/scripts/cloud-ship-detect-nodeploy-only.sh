#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-detect-nodeploy-only.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Is EVERY changed path under a declared no-deploy dir? (exit 0 = yes, 1 = no or nothing)
#
# Why a script: ship.yml's detect `run:` block sits at GHA's 21000-char expression
# ceiling (see 67f9f450d); inlining this pushed it over and the workflow failed at
# instantiation with zero jobs. The dirs are data: 1_cicd/src/ship-no-deploy-paths.json.
#
# Usage: cloud-ship-detect-nodeploy-only.sh < <changed-paths>   (ship.yml's $SUB_CHANGED)
#   cwd must be the cloud-infra checkout.
set -eu
dirs=$(jq -r '.dirs | join("|")' 1_cicd/src/ship-no-deploy-paths.json)
paths=$(grep -v '^$' || true)
[ -n "$paths" ] && ! printf '%s\n' "$paths" | grep -qvxE "($dirs)/.*"
