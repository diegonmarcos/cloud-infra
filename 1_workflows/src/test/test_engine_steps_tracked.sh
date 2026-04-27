#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Phase 25 tester — every cloud-ship-*.sh referenced by any tracked║
# ║ engine/workflow MUST itself be tracked in git.                    ║
# ║                                                                   ║
# ║ Failure mode this catches (proven 2026-04-27 ship runs            ║
# ║ 24994988037 + 24995056043): an engine-step script existed on the  ║
# ║ author's dev disk but was never `git add`'d. cloud-builder        ║
# ║ clones the repo from GitHub → script is absent → engine sources   ║
# ║ it → "No such file or directory" → first service in the matrix   ║
# ║ fails with exit 1 → cascade-skips remaining services.            ║
# ║                                                                   ║
# ║ Phase 24 already makes the engine `source` *tolerant* of missing  ║
# ║ steps, but a tolerant runtime still misbehaves silently. This     ║
# ║ phase enforces the upstream invariant: if the engine names a      ║
# ║ step, that step must be in the repo. Static, declarative, fast.   ║
# ║                                                                   ║
# ║ Data-driven (FIRE RULE 4): no hardcoded list of step files.       ║
# ║ References are extracted by grepping all tracked .sh / .yml /     ║
# ║ .json files for the `cloud-ship-*-step-*.sh` filename pattern.    ║
# ║                                                                   ║
# ║ Fix when this fails:                                              ║
# ║   git add <referenced-but-untracked-path>                         ║
# ║                                                                   ║
# ║ Usage: bash 1_workflows/src/test/test_engine_steps_tracked.sh     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
pass() { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; FAIL=1; }

echo "── Every referenced cloud-ship-*-step-*.sh MUST be tracked ──"

# Scan ENGINES only — files that source/exec other engine steps for real.
# Excluded:
#   1_workflows/src/test/    (tests mention filenames as fixtures, e.g. heredocs)
#   1_workflows/dist/        (generated mirror of src/ — duplicate references)
# Included:
#   per-service build.sh symlinks → consolidated engine
#   1_workflows/src/scripts/ engines/orchestrators
#   1_workflows/src/cicd/    workflow source
#   .github/workflows/       generated workflows (also tracked)
mapfile -t scan_files < <(
  git ls-files \
    '1_workflows/src/scripts/*.sh' \
    '1_workflows/src/cicd/*.yml' \
    '.github/workflows/*.yml' \
    'a_solutions/*/build.sh' \
  2>/dev/null | sort -u
)

# Extract every cloud-ship-*-step-*.sh filename mentioned across those files.
# Pattern is restrictive — must end in .sh and start with cloud-ship-.
mapfile -t referenced < <(
  for f in "${scan_files[@]}"; do
    [ -f "$f" ] || continue
    grep -hoE 'cloud-ship-[a-z0-9_-]+\.sh' "$f" 2>/dev/null || true
  done | sort -u
)

if [ "${#referenced[@]}" -eq 0 ]; then
  echo ""
  echo "Phase 25 engine-steps-tracked: PASS (no references found — vacuously OK)"
  exit 0
fi

CHECKED=0
for step in "${referenced[@]}"; do
  # Resolve to canonical source path. The engine clone (cloud-builder) reads
  # from 1_workflows/src/scripts/. dist/scripts is the generated mirror used
  # by the local dev loop. Both must be tracked if the script is referenced
  # so the GHA runner and the cloud-builder container both find it.
  src_path="1_workflows/src/scripts/$step"
  dist_path="1_workflows/dist/scripts/$step"

  src_tracked=0
  dist_tracked=0
  if git ls-files --error-unmatch "$src_path"  >/dev/null 2>&1; then src_tracked=1;  fi
  if git ls-files --error-unmatch "$dist_path" >/dev/null 2>&1; then dist_tracked=1; fi

  CHECKED=$((CHECKED + 1))
  if [ "$src_tracked" = 1 ] && [ "$dist_tracked" = 1 ]; then
    pass "$step"
  else
    miss=""
    [ "$src_tracked"  = 0 ] && miss="$miss $src_path"
    [ "$dist_tracked" = 0 ] && miss="$miss $dist_path"
    fail "$step — untracked in git:$miss (run: git add$miss)"
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "Phase 25 engine-steps-tracked: PASS ($CHECKED step(s) referenced, all tracked)"
  exit 0
else
  echo ""
  echo "Phase 25 engine-steps-tracked: FAIL — commit the untracked engine step files"
  exit 1
fi
