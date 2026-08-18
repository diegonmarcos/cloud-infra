#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-submodule-readonly-pre-commit.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Submodule pre-commit — submodules are READ-ONLY (silent reject).
#
# Installed into every submodule's gitdir hooks/pre-commit by
# 9_others/build.sh do_deploy. Any commit attempt inside a submodule
# fails silently — no banner, no message, just exit 1. Edits go to the
# upstream clone instead (e.g. ~/git/cloud-unix/, NOT cloud/II_Unix/);
# pin bumps come from the Auto-sync GHA workflow.
#
# Bypass: NONE.
exit 1
