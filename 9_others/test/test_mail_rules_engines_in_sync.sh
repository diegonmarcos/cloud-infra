#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ mail-rules tester — the two engine copies MUST stay identical    ║
# ║                                                                  ║
# ║ mail-rules-*.json lives in user-comm_tools-stalwart/src and is  ║
# ║ SYMLINKED into user-comm_tools-maddy/src. Replace that link with ║
# ║ a real copy and the engines silently diverge. Every rule carries ║
# ║ `engines: {maddy, stalwart}` so ONE rule set drives both engines ║
# ║ with per-engine modes — mail then files correctly in one store   ║
# ║ and not the other, which is exactly the "a copy went missing"    ║
# ║ class this system exists to prevent.                             ║
# ║                                                                  ║
# ║                                                                  ║
# ║ Also asserts every rule declares a VALID mode for both engines,  ║
# ║ so a typo ("tag_ony") fails here rather than silently behaving   ║
# ║ as drop.                                                         ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 9_others/test/test_mail_rules_engines_in_sync.sh          ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../..
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_d" != "/" ] && [ ! -d "$_d/.git" ]; do _d="$(dirname "$_d")"; done
REPO_ROOT="$_d"

MADDY="$REPO_ROOT/a_solutions/user-comm_tools-maddy/src"
STALWART="$REPO_ROOT/a_solutions/user-comm_tools-stalwart/src"

FAIL=0
pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=1; }

echo "mail-rules engine-sync:"

shopt -s nullglob
found=0
for src in "$MADDY"/mail-rules*.json; do
    found=1
    base="$(basename "$src")"
    other="$STALWART/$base"
    if [ ! -f "$other" ]; then
        fail "$base exists in tools-maddy but NOT in tools-stalwart"
        continue
    fi
    # The maddy entries are SYMLINKS into tools-stalwart, so content can only
    # diverge if the link itself is replaced by a real file (a `cp -L`, a
    # checkout without symlink support, a tool that dereferences on write).
    # Guarding the link is therefore the assertion that actually protects;
    # cmp is the fallback for the window where a fresh copy still matches.
    if [ ! -L "$src" ]; then
        fail "$base in tools-maddy is a REAL FILE, not a symlink into tools-stalwart — the two engines can now silently diverge"
    elif [ "$(cd "$(dirname "$src")" && cd "$(dirname "$(readlink "$base")")" && pwd)" != "$STALWART" ]; then
        fail "$base in tools-maddy symlinks outside tools-stalwart: $(readlink "$src")"
    elif cmp -s "$src" "$other"; then
        pass "$base symlinked to tools-stalwart, content identical"
    else
        fail "$base DIVERGED between tools-maddy and tools-stalwart (diff them)"
    fi
done

# A stalwart-only rules file is divergence too — the loop above cannot see it.
for other in "$STALWART"/mail-rules*.json; do
    base="$(basename "$other")"
    [ -f "$MADDY/$base" ] || fail "$base exists in tools-stalwart but NOT in tools-maddy"
done

[ "$found" -eq 1 ] || fail "no mail-rules*.json found under tools-maddy/src — path moved?"

# Every rule must declare a valid mode for BOTH engines.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$MADDY" <<'PY' || FAIL=1
import glob, json, os, sys
VALID = {"full", "route_only", "tag_only", "drop"}
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "mail-rules*.json"))):
    d = json.load(open(f))
    rules = d.get("rules") if isinstance(d, dict) else d
    for r in rules:
        rid = r.get("id", "<no id>")
        eng = r.get("engines") or {}
        for name in ("maddy", "stalwart"):
            mode = eng.get(name)
            if mode not in VALID:
                print(f"  FAIL {os.path.basename(f)}:{rid} engines.{name}={mode!r} "
                      f"not in {sorted(VALID)}", file=sys.stderr)
                bad += 1
if bad:
    sys.exit(1)
print("  OK   every rule declares a valid mode for both engines")
PY
else
    echo "  SKIP python3 unavailable — mode validation skipped"
fi

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "mail-rules engine-sync: PASS"
    exit 0
else
    echo ""
    echo "mail-rules engine-sync: FAIL"
    exit 1
fi
