#!/usr/bin/env bash
# #359: probe the GitHub credential each agent container DECLARES, not the one
# some shell happens to hold. For every holder in agent-credential-policy.json
# the value is decrypted from <containers>/<holder>/src/secrets.yaml and handed
# to agent-credential-audit.sh, which asks api.github.com (GET /user, read-only)
# for its X-OAuth-Scopes. It never prints the token.
#
# Exit 0  every holder's token is fine-grained, or classic within
#         allowed_classic_scopes
# Exit 1  any holder's token is over-scoped (admin:enterprise, admin:org,
#         delete_repo, ... anything beyond the allowed list), or could not be
#         decrypted or checked. Unchecked is never a pass.
#
# Holders come from the policy; test_agent_credential_scope.sh (case H) fails if
# that list differs from the sops files that really declare the key.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POLICY="${AGENT_CREDENTIAL_POLICY:-$ROOT/9_others/agent-credential-policy.json}"
AUDIT="$ROOT/9_others/src/agent-credential-audit.sh"
C="${AGENT_CONTAINERS_ROOT:-$ROOT/a_solutions}"
for t in jq sops; do command -v "$t" >/dev/null || { echo "::error::$t is required"; exit 1; }; done
[ -f "$POLICY" ] || { echo "::error::policy not found at $POLICY"; exit 1; }

var="$(jq -r .env_var "$POLICY")"
bad=0; checked=0
for h in $(jq -r '.holders[]' "$POLICY"); do
    f="$C/$h/src/secrets.yaml"
    echo "── $h"
    [ -f "$f" ] || { echo "::error::$h: $f not found"; bad=$((bad+1)); continue; }
    if ! tok="$(sops -d --extract "[\"$var\"]" "$f" 2>/dev/null)" || [ -z "$tok" ]; then
        echo "::error::$h: could not decrypt $var from its sops file"; bad=$((bad+1)); continue
    fi
    # `export` is a builtin, so the token stays off every argv (ps). Clean HOME
    # and no tree: on a CI box only the scope verdict matters.
    ( export "$var=$tok" HOME="$(mktemp -d)" AGENT_GIT_TREE=/nonexistent \
             AGENT_CREDENTIAL_POLICY="$POLICY"
      exec bash "$AUDIT" )
    r=$?; unset tok
    checked=$((checked+1))
    case "$r" in
        0) ;;
        1) echo "::error::$h declares an over-scoped $var (see excess above). Mint the token in agent-credential-policy.json diego_must_do."; bad=$((bad+1)) ;;
        *) echo "::error::$h: $var could not be checked (audit exit $r)"; bad=$((bad+1)) ;;
    esac
done

[ "$checked" -ge 1 ] || { echo "::error::no holder was checked"; exit 1; }
echo "── agent-credential-declared-guard: $checked checked, $bad failing"
[ "$bad" -eq 0 ]
