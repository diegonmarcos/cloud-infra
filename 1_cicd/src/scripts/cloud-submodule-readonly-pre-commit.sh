#!/usr/bin/env bash
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
