#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-submodule-readonly-pre-commit.sh
# ║   Engine : 1_workflows/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Submodule pre-commit — submodules are READ-ONLY (silent reject).
#
# Installed into every submodule's gitdir hooks/pre-commit by
# 1_workflows/build.sh do_deploy. Any commit attempt inside a submodule
# fails silently — no banner, no message, just exit 1. Edits go to the
# upstream clone instead (e.g. ~/git/unix/, NOT cloud/III_unix/);
# pin bumps come from the Auto-sync GHA workflow.
#
# Bypass: NONE.
exit 1
