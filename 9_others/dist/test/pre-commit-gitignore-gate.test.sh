#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/pre-commit-gitignore-gate.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Regression: the pre-commit hook auto-stages whole regenerated directories
# (1_cloud-configs/dist/, a_solutions/). On 2026-08-23 a .gitignore regeneration
# raced those adds and swept 131 sops-decrypted dist/.secrets* files into a
# commit; GitHub push protection caught it, the hook did not. The gitignore
# detector only ever saw the USER's staging, never the hook's own.
#
# These cases pin both call sites of assert_no_forced_gitignored.
set -u
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/0_git/dist/hooks/pre-commit"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

newrepo() {
  R=$(mktemp -d); cd "$R" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  printf '**/dist/.secrets.d/\n**/dist/.secrets.json\n' > .gitignore
  mkdir -p svc/dist/.secrets.d
  printf 'ghp_notarealtoken\n' > svc/dist/.secrets.d/GITHUB_TOKEN
  printf 'ok\n' > svc/app.txt
  git add .gitignore svc/app.txt; git commit -qm init
}

# 1) clean staging passes
newrepo
printf 'changed\n' > svc/app.txt; git add svc/app.txt
if bash "$HOOK" >/dev/null 2>&1; then ok "clean staging passes"; else nope "clean staging passes"; fi

# 2) THE BUG: .gitignore absent when a directory is added -> ignored file staged
#    -> the final gate must refuse once .gitignore is back.
newrepo
mv .gitignore /tmp/gi.$$          # the regeneration window
git add svc                        # sweeps the secret in, no rules to obey
mv /tmp/gi.$$ .gitignore           # regeneration completes
git diff --cached --name-only | grep -q 'GITHUB_TOKEN' \
  && ok "repro: secret really is staged" || nope "repro: secret really is staged"
OUT=$(bash "$HOOK" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "gate refuses ignored file staged during the race" \
                || nope "gate refuses ignored file staged during the race (rc=$RC)"
printf '%s' "$OUT" | grep -q 'GITHUB_TOKEN' \
  && ok "gate names the offending path" || nope "gate names the offending path"

echo "pre-commit-gitignore-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
