#!/usr/bin/env bash
# #467 follow-up: the SSO gaps closed on 2026-09-25 must stay closed.
# Reads 9_others/sso-directory-policy.json#sso_gaps_closed and checks the
# declarations in cloud-u-containers: Radicale authenticates against Stalwart
# (not maddy), the stale OIDC clients stay deleted, Vaultwarden signup stays off.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POLICY="$ROOT/9_others/sso-directory-policy.json"
[ -f "$POLICY" ] || { echo "::error::policy not found at $POLICY"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq is required"; exit 1; }

C=""
for _try in "$ROOT/a_solutions" "$ROOT/../cloud-u-containers"; do
    [ -d "$_try/infra-sec_authelia" ] && { C="$(cd "$_try" && pwd)"; break; }
done
[ -n "$C" ] || { echo "::error::cloud-u-containers checkout not found (a_solutions or ../cloud-u-containers)"; exit 1; }

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

for id in $(jq -r '.sso_gaps_closed.removed_oidc_clients[]' "$POLICY"); do
    n="$(jq --arg id "$id" '[.clients[] | select(.client_id == $id)] | length' "$C/infra-sec_authelia/src/oidc-clients.json")"
    ck "OIDC client '$id' is not declared" "$n" "0"
done

want="$(jq -r .sso_gaps_closed.radicale_auth_upstream "$POLICY")"
bad="$(jq -r .sso_gaps_closed.radicale_forbidden_upstream "$POLICY")"
for d in $(jq -r '.sso_gaps_closed.radicale_dirs[]' "$POLICY"); do
    ck "$d flake reads its IMAP upstream from $want" "$(grep -c "svc\.$want\." "$C/$d/src/flake.nix")" "2"
    ck "$d flake does not read $bad" "$(grep -ci "svc\.$bad\." "$C/$d/src/flake.nix")" "0"
    ck "$d config template has no $bad reference" "$(grep -ci "$bad" "$C/$d/src/templates/config.tpl")" "0"
done

got="$(sed -n 's/^ *SIGNUPS_ALLOWED *= *"\([a-z]*\)";.*/\1/p' "$C/user-vault_vaultwarden/src/compose.nix")"
ck "Vaultwarden SIGNUPS_ALLOWED" "$got" "$(jq -r .sso_gaps_closed.vaultwarden_signups_allowed "$POLICY")"

echo "── sso-gaps-closed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
