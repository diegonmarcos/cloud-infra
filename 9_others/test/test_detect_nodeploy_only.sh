#!/usr/bin/env bash
# Tester for cloud-ship-detect-nodeploy-only.sh + 1_cicd/src/ship-no-deploy-paths.json.
# A containers-push whose every path is declared no-deploy is a proven no-op
# (green); anything else must stay verdict=empty (red) so a detection miss
# cannot pass as success. #760: a push of only fleet plumbing went red.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/1_cicd/src/scripts/cloud-ship-detect-nodeploy-only.sh"
P=0; F=0
t() { local want="$1" name="$2"; shift 2; if printf '%s\n' "$@" | (cd "$ROOT" && bash "$S"); then got=0; else got=1; fi
      [ "$got" = "$want" ] && { P=$((P+1)); echo "  ok   $name"; } || { F=$((F+1)); echo "  FAIL $name (exit $got, want $want)"; }; }
t 0 "_dispatch only"                      _dispatch/prep.sh
t 0 "fleet plumbing only (#760 push)"     .githooks/history-gate .github/workflows/leak-scan.yml .gitleaks.toml _dispatch/prep.sh
t 1 "a service path is NOT a no-op"       .githooks/pre-push infra-obs_dagu/src/dags/x.yaml
t 1 "an undeclared root file is NOT"      .gitleaks.toml config.json
t 1 "dot is literal: xgithub/ is NOT .github/" xgithub/workflows/a.yml
t 1 "a declared FILE name is exact, not a prefix" .gitleaks.toml.bak
t 1 "nothing changed is not a proven no-op"
echo "test_detect_nodeploy_only: $P passed, $F failed"
[ "$F" -eq 0 ]
