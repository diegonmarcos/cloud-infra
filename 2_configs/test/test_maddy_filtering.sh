#!/usr/bin/env bash
# test_maddy_filtering.sh — build-time guard for Maddy's two-script
# Sieve-subset filtering architecture.
#
# Asserts:
#   1. The two active scripts exist + executable + name advertises layer
#   2. The 3 retired scripts are archived in src/z-archive/, NOT in src/
#   3. flake.nix#extraAssets references active scripts only (not z-archive)
#   4. compose.nix mounts both active scripts at /usr/local/bin/
#   5. maddy.conf.tpl.tpl uses the new delivery-time path
#   6. build.json#lifecycle has post-hoc-* entries (not the old dedupe/cleanup)
#   7. build.json#docker.runtime_packages.apk includes sqlite + jq
#   8. Both active scripts pass `sh -n` syntax check
#   9. Post-hoc script supports all required subcommands in --help
#  10. z-archive/README.md present (transition documentation)
set -uo pipefail
# Resolve cloud root via $0 BEFORE any cd (path-stable from any cwd).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLOUD_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$CLOUD_ROOT/2_configs"

PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then echo "[PASS] $label"; PASS=$((PASS+1))
  else echo "[FAIL] $label"; FAIL=$((FAIL+1)); fi
}
MADDY="$CLOUD_ROOT/a_solutions/aa-sui_tools-maddy"
SRC="$MADDY/src"

# 1. Two active scripts present + executable + correctly named
check "delivery-time script present + executable" \
    bash -c "[ -x '$SRC/mail-sieve-subset-delivery-time.sh' ]"
check "post-hoc script present + executable" \
    bash -c "[ -x '$SRC/mail-sieve-subset-post-hoc.sh' ]"

# 2. Old scripts archived (not in src/)
for old in dedupe-inbox.sh dedupe-folders.sh cleanup-stale-mailboxes.sh; do
    check "archived: $old NOT in src/ (must be in z-archive/)" \
        bash -c "[ ! -e '$SRC/$old' ]"
    check "archived: $old IS in src/z-archive/" \
        test -f "$SRC/z-archive/$old"
done

# Old name MUST not exist
check "old mail-filter.sh removed (renamed)" \
    bash -c "[ ! -e '$SRC/mail-filter.sh' ]"

# 3. flake.nix references active only
FLAKE="$SRC/flake.nix"
check "flake.nix: extraAssets includes mail-sieve-subset-delivery-time.sh" \
    grep -q "./mail-sieve-subset-delivery-time.sh" "$FLAKE"
check "flake.nix: extraAssets includes mail-sieve-subset-post-hoc.sh" \
    grep -q "./mail-sieve-subset-post-hoc.sh" "$FLAKE"
check "flake.nix: NO Nix-path reference to z-archive (./z-archive must not appear)" \
    bash -c "! grep -qE '\\./z-archive[/.]' '$FLAKE'"
check "flake.nix: NO reference to old mail-filter.sh" \
    bash -c "! grep -qE '\\./mail-filter\\.sh' '$FLAKE'"
check "flake.nix: NO reference to dedupe-inbox.sh" \
    bash -c "! grep -qE '\\./dedupe-inbox\\.sh' '$FLAKE'"

# 4. compose.nix mounts both at /usr/local/bin/
COMPOSE="$SRC/compose.nix"
check "compose.nix mounts delivery-time script at /usr/local/bin/mail-sieve-subset-delivery-time" \
    grep -q "/usr/local/bin/mail-sieve-subset-delivery-time" "$COMPOSE"
check "compose.nix mounts post-hoc script at /usr/local/bin/mail-sieve-subset-post-hoc" \
    grep -q "/usr/local/bin/mail-sieve-subset-post-hoc" "$COMPOSE"
check "compose.nix: NO reference to old /usr/local/bin/mail-filter (without -sieve)" \
    bash -c "! grep -qE '/usr/local/bin/mail-filter\$|/usr/local/bin/mail-filter\\\"' '$COMPOSE'"

# 5. maddy.conf.tpl uses new command path
CONF="$SRC/templates/maddy.conf.tpl.tpl"
check "maddy.conf.tpl.tpl: imap_filter command = mail-sieve-subset-delivery-time" \
    grep -q "command /usr/local/bin/mail-sieve-subset-delivery-time" "$CONF"
check "maddy.conf.tpl.tpl: NO old mail-filter command" \
    bash -c "! grep -qE 'command /usr/local/bin/mail-filter\\b' '$CONF'"

# 6. build.json#lifecycle uses post-hoc-* entries
BJ="$MADDY/build.json"
for sub in integrity-check recover-headers integrity-fix apply-rules dedupe cleanup-mailboxes all; do
    check "build.json#lifecycle.post-hoc-$sub present" \
        bash -c "jq -e '.lifecycle.\"post-hoc-$sub\"' '$BJ' >/dev/null"
done
check "build.json#lifecycle has NO old 'cleanup' entry" \
    bash -c "[ \"\$(jq -r '.lifecycle.cleanup // \"absent\"' '$BJ')\" = 'absent' ]"
check "build.json#lifecycle has NO old 'dedupe' entry" \
    bash -c "[ \"\$(jq -r '.lifecycle.dedupe // \"absent\"' '$BJ')\" = 'absent' ]"

# 7. runtime_packages includes sqlite + jq
check "build.json: docker.runtime_packages.apk includes sqlite" \
    bash -c "jq -r '.docker.runtime_packages.apk' '$BJ' | grep -q sqlite"
check "build.json: docker.runtime_packages.apk includes jq" \
    bash -c "jq -r '.docker.runtime_packages.apk' '$BJ' | grep -q jq"

# 8. Syntax check on both scripts
check "delivery-time script: sh -n syntax check" \
    sh -n "$SRC/mail-sieve-subset-delivery-time.sh"
check "post-hoc script: sh -n syntax check" \
    sh -n "$SRC/mail-sieve-subset-post-hoc.sh"

# 9. Post-hoc --help advertises all subcommands
HELP_FILE="$(mktemp)"
"$SRC/mail-sieve-subset-post-hoc.sh" --help >"$HELP_FILE" 2>&1 || true
for sub in integrity-check integrity-fix recover-headers apply-rules dedupe cleanup-mailboxes all; do
    check "post-hoc --help advertises subcommand: $sub" \
        grep -q "$sub" "$HELP_FILE"
done
rm -f "$HELP_FILE"

# 10. z-archive transition documentation
check "src/z-archive/README.md present (transition docs)" \
    test -f "$SRC/z-archive/README.md"
check "z-archive README explains why archived" \
    grep -q "Why kept" "$SRC/z-archive/README.md"
check "z-archive README states delete-after criteria" \
    grep -q "When safe to delete" "$SRC/z-archive/README.md"

# 11. Schema version pin in delivery-time script
check "delivery-time: pins schema_version=2" \
    grep -q 'SCHEMA_VER.*= "2"' "$SRC/mail-sieve-subset-delivery-time.sh"

# 12. Single jq invocation (combined eval) — no chained two-jq pattern
check "delivery-time: single jq -n (combined ctx + eval — no two-jq chain)" \
    bash -c "[ \"\$(grep -c '^OUT=' '$SRC/mail-sieve-subset-delivery-time.sh')\" = '1' ]"

echo
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
