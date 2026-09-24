#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_agent_credential_scope.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #439: tests 9_others/src/agent-credential-audit.sh and the data in
# 9_others/agent-credential-policy.json.
#
# Runs the REAL audit script. GitHub is replaced by a stub curl that returns a
# stored response header, and gh by a stub that returns a stored token. So the
# checks work offline and give the same result on every machine. Expected values
# are computed from the policy file, never typed in here:
#   excess = measured scopes minus allowed_classic_scopes
#
# The tester also compares the policy's holder list with the containers whose
# sops files really declare the token, so a new container cannot get the agent
# credential without anyone noticing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/9_others/src/agent-credential-audit.sh"
POLICY="$ROOT/9_others/agent-credential-policy.json"
for f in "$TOOL" "$POLICY"; do [ -f "$f" ] || { echo "::error::missing $f"; exit 1; }; done
command -v jq >/dev/null || { echo "::error::jq is required"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── stubs ─────────────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$STUB_CALLS"
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$STUB_SEEN_HEADER";; esac; done
printf 'HTTP/2 %s\r\n' "${STUB_CODE:-200}"
# Case I: a token containing OVER gets STUB_OVER_SCOPES, so one holder can be
# over-scoped while the others are not.
for a in "$@"; do case "$a" in @*) grep -q OVER "${a#@}" && [ -n "${STUB_OVER_SCOPES:-}" ] && STUB_SCOPES="$STUB_OVER_SCOPES";; esac; done
[ -n "${STUB_SCOPES+x}" ] && printf 'x-oauth-scopes: %s\r\n' "$STUB_SCOPES"
printf 'content-type: application/json\r\n\r\n'
EOF
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && [ -n "${STUB_GH_TOKEN:-}" ] && { printf '%s\n' "$STUB_GH_TOKEN"; exit 0; }
exit 1
EOF
# sops -d --extract '["VAR"]' FILE -> contents of FILE.tok; no .tok = decrypt fails.
cat > "$T/bin/sops" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"; [ -f "$f.tok" ] && { cat "$f.tok"; exit 0; }; exit 1
EOF
chmod +x "$T/bin/curl" "$T/bin/gh" "$T/bin/sops"

var="$(jq -r .env_var "$POLICY")"
FAKE="fake-token-for-test-439"
measured="$(jq -r '.measured_2026_09_24.x_oauth_scopes | join(", ")' "$POLICY")"
want_excess="$(jq -r '(.measured_2026_09_24.x_oauth_scopes - .allowed_classic_scopes) | sort | join(" ")' "$POLICY")"
allowed="$(jq -r '.allowed_classic_scopes | join(", ")' "$POLICY")"

# run <case> [VAR=val ...]: runs the audit with a clean env and the stubs first
# on PATH. Sets $out and $rc.
run() {
    local c="$1"; shift
    : > "$T/calls.$c"
    out="$(env -i PATH="$T/bin:$PATH" HOME="$T/home" AGENT_GIT_TREE="$T/tree" \
        STUB_CALLS="$T/calls.$c" STUB_SEEN_HEADER="$T/hdr.$c" "$@" bash "$TOOL" 2>&1)"; rc=$?
}
calls() { wc -l < "$T/calls.$1" | tr -d ' '; }

echo "── A: the token measured 2026-09-24 is reported over-scoped"
run A "$var=$FAKE" STUB_SCOPES="$measured"
ck "A exit 1" "$rc" "1"
ck "A excess == measured - allowed (from policy)" \
   "$(printf '%s\n' "$out" | sed -n 's/^  excess: //p' | sort | paste -sd' ' -)" "$want_excess"
ck "A delete_repo is in the computed excess (policy not emptied)" \
   "$(printf '%s\n' $want_excess | grep -cx delete_repo)" "1"
ck "A token sent in a header file, never on argv" "$(grep -c "$FAKE" "$T/hdr.A")" "1"
ck "A token never printed" "$(printf '%s' "$out" | grep -c "$FAKE")" "0"

echo "── B: classic token holding exactly the allowed scopes passes"
run B "$var=$FAKE" STUB_SCOPES="$allowed"
ck "B exit 0" "$rc" "0"

echo "── C: fine-grained token (no x-oauth-scopes header) passes, labelled"
run C "$var=fake-fine-grained-439"
ck "C exit 0" "$rc" "0"
ck "C says fine-grained" "$(printf '%s' "$out" | grep -c '^fine-grained token')" "1"

echo "── D: no credential anywhere -> exit 2 before any network call"
run D
ck "D exit 2" "$rc" "2"
ck "D curl never called" "$(calls D)" "0"

echo "── E: env var empty but gh holds a token (hermes shape) -> still audited"
run E STUB_GH_TOKEN="$FAKE" STUB_SCOPES="$measured"
ck "E exit 1 (audited the gh token)" "$rc" "1"
ck "E source reported as gh" "$(printf '%s' "$out" | grep -c '^credential source: gh auth token')" "1"

echo "── F: GitHub rejects the token -> exit 2, never a pass"
run F "$var=$FAKE" STUB_CODE=401
ck "F exit 2" "$rc" "2"

echo "── G: a repo-local store helper and a plaintext copy are both reported"
mkdir -p "$T/tree/r"; git init -q "$T/tree/r"; git -C "$T/tree/r" config credential.helper store
printf 'https://x-access-token:%s@github.com\n' "$FAKE" > "$T/home/.git-credentials"
run G "$var=$FAKE" STUB_SCOPES="$allowed"
ck "G store helper reported" "$(printf '%s' "$out" | grep -c 'credential.helper=store.*/tree/r$')" "1"
ck "G plaintext copy reported" "$(printf '%s' "$out" | grep -c 'plaintext copy on disk: .*/.git-credentials$')" "1"
rm -rf "$T/tree" "$T/home/.git-credentials"

echo "── H: policy.holders == containers whose sops secrets declare the token"
C=""
for _try in "$ROOT/a_solutions" "$ROOT/../cloud-u-containers"; do
    [ -d "$_try/user-ai_my-ai_claude-api" ] && { C="$_try"; break; }
done
if [ -z "$C" ]; then
    fail=$((fail+1)); echo "  FAIL H cloud-u-containers checkout not found (a_solutions or ../cloud-u-containers)"
else
    actual="$(grep -l "^$var:" "$C"/*/src/secrets.yaml 2>/dev/null | sed "s|^$C/||; s|/src/secrets.yaml$||" | sort | paste -sd' ' -)"
    ck "H holders match sops" "$actual" "$(jq -r '.holders | sort | join(" ")' "$POLICY")"
    src="$(jq -r .repository_access.source "$POLICY")"
    n="$(jq -r "$(jq -r .repository_access.jq "$POLICY") | length" "$C/${src#cloud-u-containers/}" 2>/dev/null)"
    ck "H repository_access resolves to >=1 repo from runtime.repos" "$([ "${n:-0}" -ge 1 ] && echo yes)" "yes"
fi

echo "── I: the guard probes the token each holder DECLARES in sops (#359)"
GUARD="$ROOT/9_others/src/agent-credential-declared-guard.sh"
holders="$(jq -r '.holders[]' "$POLICY")"
nh="$(printf '%s\n' $holders | grep -c .)"
first="$(printf '%s\n' $holders | head -1)"
# The scope the brief names, taken from the measured token, never typed as data.
enterprise="$(jq -r '(.measured_2026_09_24.x_oauth_scopes - .allowed_classic_scopes)[] | select(. == "admin:enterprise")' "$POLICY")"
ck "I admin:enterprise is measured AND outside allowed_classic_scopes" "$enterprise" "admin:enterprise"
mkc() { # mkc <holder> <token|-> : fake container sops file (+ decryptable value)
    mkdir -p "$T/c/$1/src"; printf '%s: ENC[AES256_GCM,data:x,type:str]\n' "$var" > "$T/c/$1/src/secrets.yaml"
    rm -f "$T/c/$1/src/secrets.yaml.tok"; [ "$2" = "-" ] || printf '%s' "$2" > "$T/c/$1/src/secrets.yaml.tok"; }
rung() { local c="$1"; shift; : > "$T/calls.$c"
    out="$(env -i PATH="$T/bin:$PATH" STUB_CALLS="$T/calls.$c" STUB_SEEN_HEADER="$T/hdr.$c" \
        AGENT_CONTAINERS_ROOT="$T/c" "$@" bash "$GUARD" 2>&1)"; rc=$?; }

for h in $holders; do mkc "$h" "fake-ok-$h-359"; done
rung I1 STUB_SCOPES="$allowed"
ck "I1 every holder within policy -> exit 0" "$rc" "0"
ck "I1 every holder was probed (from policy.holders)" "$(calls I1)" "$nh"

mkc "$first" "fake-OVER-$first-359"
rung I2 STUB_SCOPES="$allowed" STUB_OVER_SCOPES="$allowed, $enterprise"
ck "I2 one holder declares admin:enterprise -> exit 1" "$rc" "1"
ck "I2 the error names that holder" "$(printf '%s' "$out" | grep -c "::error::$first declares an over-scoped")" "1"
ck "I2 only that holder is flagged" "$(printf '%s' "$out" | grep -c 'declares an over-scoped')" "1"
ck "I2 admin:enterprise is listed as excess" "$(printf '%s\n' "$out" | grep -cx "  excess: $enterprise")" "1"
ck "I2 no token printed" "$(printf '%s' "$out" | grep -c 'fake-\(ok\|OVER\)-')" "0"

mkc "$first" "-"
rung I3 STUB_SCOPES="$allowed"
ck "I3 a holder whose sops value cannot be decrypted -> exit 1, never a pass" "$rc" "1"
ck "I3 it says so" "$(printf '%s' "$out" | grep -c "::error::$first: could not decrypt")" "1"

echo "── agent-credential-scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
