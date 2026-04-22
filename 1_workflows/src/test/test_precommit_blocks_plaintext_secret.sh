#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
# test_precommit_blocks_plaintext_secret.sh
#
# Reproduces the 2026-04-17 stalwart leak: `secrets.yaml.new` committed
# in plaintext (not sops-encrypted) slipped past every filename-based
# defense. This asserts the content-scan blocks any secret-named file
# that isn't sops-encrypted, regardless of suffix.
# ════════════════════════════════════════════════════════════════════
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/pre-commit"
[ -x "$HOOK" ] || { echo "FAIL: pre-commit hook missing: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q && git config user.email t@t && git config user.name t
echo "ok" > README.md && git add README.md && git commit -qm seed

# Case 1: plaintext secrets.yaml.new (the actual leak)
cat > secrets.yaml.new <<'EOF'
# Stalwart Mail Server Secrets
ADMIN_PASSWORD: x1NdureaBojGCVvkGuCKv1EDOn9JUham
DKIM_PRIVATE_KEY_B64: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t
EOF
git add secrets.yaml.new
if "$HOOK" >/tmp/h 2>&1; then
    fail "hook did NOT block secrets.yaml.new (STALWART LEAK REPRODUCED)"
    cat /tmp/h
else
    pass "secrets.yaml.new blocked"
fi
git reset HEAD >/dev/null; rm secrets.yaml.new

# Case 2: other obfuscated names — .draft, .bak, .old
for suffix in .draft .bak .old; do
    f="secrets.yaml$suffix"
    echo "ADMIN_PASSWORD: abc123" > "$f"
    git add "$f"
    if "$HOOK" >/dev/null 2>&1; then
        fail "hook missed $f"
    else
        pass "$f blocked"
    fi
    git reset HEAD >/dev/null; rm "$f"
done

# Case 3: sops-encrypted secrets.yaml.new → allowed
cat > secrets.yaml.new <<'EOF'
ADMIN_PASSWORD: ENC[AES256_GCM,data:xyz,iv:abc,tag:def,type:str]
sops:
    version: 3.9.0
EOF
git add secrets.yaml.new
if "$HOOK" >/dev/null 2>&1; then
    pass "sops-encrypted secrets.yaml.new allowed"
else
    fail "hook false-positived on sops-encrypted file"
fi
git reset HEAD >/dev/null; rm secrets.yaml.new

# Case 4: code file with secret name, no inline value → allowed
cat > cloud-ship-secrets.sh <<'EOF'
#!/bin/sh
# Decrypt secrets with sops
sops -d --output-type json "$secrets_file" > "$DIST_DIR/.secrets"
EOF
git add cloud-ship-secrets.sh
if "$HOOK" >/dev/null 2>&1; then
    pass "shell script handling secrets (no inline values) allowed"
else
    fail "hook false-positived on legit script"
fi
git reset HEAD >/dev/null; rm cloud-ship-secrets.sh

# Case 5: plaintext jwks-named yaml → blocked
cat > my-jwks.yaml <<'EOF'
JWKS_PRIVATE_KEY: abc123-not-encrypted
EOF
git add my-jwks.yaml
if "$HOOK" >/dev/null 2>&1; then
    fail "hook missed my-jwks.yaml"
else
    pass "my-jwks.yaml blocked"
fi
git reset HEAD >/dev/null; rm my-jwks.yaml

# Case 6: README prose with 'password' → allowed
echo "See README for password rotation steps." > README.md
git add README.md
if "$HOOK" >/dev/null 2>&1; then
    pass "README prose allowed (no inline secret pattern)"
else
    fail "hook false-positived on README"
fi

printf '\n═══ %d pass / %d fail ═══\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
