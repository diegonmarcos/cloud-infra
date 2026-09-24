#!/usr/bin/env bash
# #467: checks the "no LDAP directory" decision in 9_others/sso-directory-policy.json.
#
# That decision is correct only while nothing in the fleet authenticates against
# LDAP. This tester:
#   1. scans every live container service for the policy's LDAP consumer
#      markers. The set of consumers it finds must equal
#      declared_ldap_consumers.
#   2. reads Authelia's RENDERED config (the dist file that ships) and checks
#      the authentication backend. It reads the rendered file, not the
#      template, so a change in the renderer is caught too.
#   3. if any consumer is declared, requires the backend to be ldap. A consumer
#      pointing at a directory that does not exist is the failure this guards.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POLICY="$ROOT/9_others/sso-directory-policy.json"
[ -f "$POLICY" ] || { echo "::error::policy not found at $POLICY"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq is required"; exit 1; }

# cloud-u-containers: at a_solutions on the CI runner, as a sibling clone locally.
# If neither is there, FAIL. Skipping would leave the scan silently empty.
C=""
for _try in "$ROOT/a_solutions" "$ROOT/../cloud-u-containers"; do
    [ -f "$_try/$(jq -r .authelia_rendered_config "$POLICY")" ] && { C="$(cd "$_try" && pwd)"; break; }
done
[ -n "$C" ] || { echo "::error::cloud-u-containers checkout not found (a_solutions or ../cloud-u-containers)"; exit 1; }

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

prune=(); while IFS= read -r d; do prune+=(-name "$d" -o); done < <(jq -r '.exclude_dirs[]' "$POLICY"); unset 'prune[-1]'
names=(); while IFS= read -r e; do names+=(-name "*.$e" -o); done < <(jq -r '.file_extensions[]' "$POLICY"); unset 'names[-1]'
marks=(); while IFS= read -r m; do marks+=(-e "$m"); done < <(jq -r '.ldap_consumer_markers[]' "$POLICY")

# Each consumer is reported as its service dir (the first path component under C).
found="$(find "$C" \( "${prune[@]}" \) -prune -o -type f \( "${names[@]}" \) -print0 \
    | xargs -0 grep -lF "${marks[@]}" -- 2>/dev/null \
    | sed "s|^$C/||; s|/.*||" | sort -u | paste -sd' ' -)"
declared="$(jq -r '.declared_ldap_consumers | sort | join(" ")' "$POLICY")"
[ -n "$found" ] && echo "  LDAP consumers found: $found"
ck "LDAP consumers found in the fleet == declared_ldap_consumers (#467)" "$found" "$declared"

cfg="$C/$(jq -r .authelia_rendered_config "$POLICY")"
backend="$(awk '/^authentication_backend:/{getline; sub(/^[[:space:]]+/,""); sub(/:.*/,""); print; exit}' "$cfg")"
ck "rendered Authelia authentication_backend == policy.authelia_backend" "$backend" "$(jq -r .authelia_backend "$POLICY")"

if [ -n "$declared" ]; then
    ck "LDAP consumers exist, so Authelia must run an ldap backend" "$backend" "ldap"
fi

echo "── sso-ldap-consumers: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
