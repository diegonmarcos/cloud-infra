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
for sub in integrity-check integrity-fix dedupe cleanup-mailboxes apply-rules apply-rules-dry-run all; do
    check "build.json#lifecycle.post-hoc-$sub present" \
        bash -c "jq -e '.lifecycle.\"post-hoc-$sub\"' '$BJ' >/dev/null"
done
# recover-headers stays INTENTIONALLY absent: missing-body rows are
# unrecoverable; integrity-fix is the right action (see build.json _doc).
check "build.json#lifecycle.post-hoc-recover-headers INTENTIONALLY absent" \
    bash -c "[ \"\$(jq -r '.lifecycle.\"post-hoc-recover-headers\" // \"absent\"' '$BJ')\" = 'absent' ]"
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
for sub in integrity-check integrity-fix dedupe cleanup-mailboxes apply-rules all; do
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

# 12b. post-hoc dispatch case includes apply-rules (catches removed-branch
# regression: lifecycle entry could exist while the script silently fails).
check "post-hoc: dispatch case has 'apply-rules' branch" \
    grep -qE '^[[:space:]]*apply-rules\)' "$SRC/mail-sieve-subset-post-hoc.sh"

# 12c. apply-rules delegates rule evaluation to delivery-time (single SoT) —
# detects future regressions that re-implement the jq logic in post-hoc.
check "post-hoc: apply-rules delegates to mail-sieve-subset-delivery-time" \
    grep -q 'mail-sieve-subset-delivery-time' "$SRC/mail-sieve-subset-post-hoc.sh"

# 12d. apply-rules reads scan via input redirection, NOT a pipeline.
# Pipeline + `set -e` + `[ ] &&` short-circuit at EOF causes the script
# to exit silently right after the last row (SCANNED % 200 != 0 → exit 1).
# Asserts the loop is `done < "$SCAN"`, not `sq … | while`.
check "post-hoc: apply-rules scan loop uses input redirection (not pipeline)" \
    grep -qE 'done < "\$SCAN"' "$SRC/mail-sieve-subset-post-hoc.sh"

# 12e. apply-rules converts cachedHeader JSON → RFC822 before piping to
# delivery-time. go-imap-sql stores headers as `{"From":["…"], …}`, but
# delivery-time's awk get_header expects raw `Field: value\n`. Without
# the conversion, get_header finds no fields and EVERY message falls
# through to routing_default (observed: 2104/2104 → fallback folder).
check "post-hoc: apply-rules converts cachedHeader JSON → RFC822 (jq to_entries)" \
    grep -q 'to_entries\[\] | "\\(.key): \\(.value | join' "$SRC/mail-sieve-subset-post-hoc.sh"

# 13. Embedded jq program compiles. `sh -n` only validates POSIX shell;
# the jq script lives inside a single-quoted heredoc and was historically
# broken (missing `;` between `def` definitions caused jq to error at EOF
# and Maddy to fall back to INBOX-only delivery for every message).
# This check extracts the jq body between `--slurpfile rf "$RULES" '` and
# the matching closing `')"`, then runs `jq -n -f` with the same --arg
# bindings the script uses — fails fast on any compile error.
JQ_BODY="$(mktemp)"
python3 - "$SRC/mail-sieve-subset-delivery-time.sh" "$JQ_BODY" <<'PY' || true
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"--slurpfile rf \"\$RULES\" '(.*?)'\)\"", src, re.DOTALL)
open(sys.argv[2], 'w').write(m.group(1) if m else '')
PY
check "delivery-time: embedded jq program compiles (jq -n -f)" \
    bash -c "[ -s '$JQ_BODY' ] && jq -n -r \
        --arg acct '' --arg sender '' --arg rcpt '' \
        --arg from_dom '' --arg from_addr '' \
        --arg to '' --arg cc '' --arg bcc '' \
        --arg reply_to '' --arg subject '' --arg list_id '' \
        --arg headers '' \
        --slurpfile rf '$MADDY/dist/assets/mail-rules.json' \
        -f '$JQ_BODY' >/dev/null 2>&1"
rm -f "$JQ_BODY"

echo
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
