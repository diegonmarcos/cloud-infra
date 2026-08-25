#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ mail filter-views tester — the size-axis partition invariant     ║
# ║                                                                  ║
# ║ jmap-sorter maintains cross-cutting A*-F* view mailboxes. The    ║
# ║ axis named by filters.partition_axis must really PARTITION —     ║
# ║ its buckets half-open [lo,hi), tiling the whole range, so every  ║
# ║ message lands in exactly ONE. Edit a boundary by one byte and    ║
# ║ the invariant breaks silently: an overlap double-files a message ║
# ║ into two size folders, a gap drops it from all of them.          ║
# ║                                                                  ║
# ║ NOTE: the sorter used to ALSO use membership in this axis as a   ║
# ║ "static views already computed" sentinel, to skip re-evaluating  ║
# ║ non-volatile views. That was removed (2026-08-25) — it recorded  ║
# ║ THAT static views ran, not WHICH, so any newly-added static      ║
# ║ view stayed permanently empty for pre-existing mail. The         ║
# ║ partition invariant is still worth asserting on its own merit.   ║
# ║                                                                  ║
# ║ Ported from src/code/test_filter_views.py, which never ran in    ║
# ║ CI. Runs against the SOURCE rules, not dist/ (generated).        ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   bash 9_others/test/test_mail_filter_views_partition.sh         ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eo pipefail

# Repo root by upward search, not a fixed ../../..
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_d" != "/" ] && [ ! -d "$_d/.git" ]; do _d="$(dirname "$_d")"; done
REPO_ROOT="$_d"

RULES="$REPO_ROOT/a_solutions/user-comm_tools-stalwart/src/mail-rules-general.json"

FAIL=0
pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "mail filter-views partition:"

if [ ! -f "$RULES" ]; then
  fail "rules file not found: $RULES"
  echo; echo "mail filter-views partition: FAIL"; exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP python3 unavailable — cannot evaluate predicates"
  echo; echo "mail filter-views partition: SKIP"; exit 0
fi

OUT="$(python3 - "$RULES" <<'PY'
import json, sys

f = json.load(open(sys.argv[1]))["filters"]
views = f["views"]
axis  = f.get("partition_axis")
bad   = []

# ── every view must declare axis + volatile ────────────────────────
missing = [v["folder"] for v in views if "axis" not in v or "volatile" not in v]
if missing:
    bad.append("views missing axis/volatile: " + ", ".join(missing))
else:
    print("OK|every view declares axis + volatile (%d views)" % len(views))

# ── partition_axis must exist and be entirely STATIC ───────────────
if not axis:
    bad.append("filters.partition_axis is unset — no axis declares itself "
               "the one that tiles its range exactly once")
else:
    part = [v for v in views if v.get("axis") == axis]
    if not part:
        bad.append("partition_axis=%r names no view — data shape changed" % axis)
    elif any(v.get("volatile") for v in part):
        vol = [v["folder"] for v in part if v.get("volatile")]
        bad.append("partition axis %r has volatile view(s) %s — a partition "
                   "over a property that changes over time cannot tile "
                   "stably" % (axis, vol))
    else:
        nvol = sum(1 for v in views if v.get("volatile"))
        print("OK|partition_axis=%r is static (%d volatile view(s) "
              "elsewhere)" % (axis, nvol))

# ── the partition must tile: exactly one bucket per probe ──────────
def hit(p, size):
    t = p["type"]
    if t == "size_min":   return size >= p["bytes"]
    if t == "size_max":   return size <  p["bytes"]
    if t == "size_range": return p["min"] <= size < p["max"]
    return None   # not a size predicate

part = [v for v in views if v.get("axis") == axis] if axis else []
part = [v for v in part if hit(v["predicate"], 0) is not None]

if not part:
    bad.append("no size-partition views found — data shape changed")
else:
    # every declared boundary, and each boundary -1 / +1
    bounds = set()
    for v in part:
        p = v["predicate"]
        for k in ("bytes", "min", "max"):
            if k in p: bounds.add(p[k])
    probes = sorted({0, 1 << 30} | {b + d for b in bounds for d in (-1, 0, 1)} - {-1})

    for size in probes:
        n = sum(1 for v in part if hit(v["predicate"], size))
        if n != 1:
            bad.append("size=%d lands in %d of %d partition views (want exactly 1)"
                       % (size, n, len(part)))
    if not any(b.startswith("size=") for b in bad):
        print("OK|%d sizes each land in exactly 1 of %d partition views "
              "(boundaries: %s)" % (len(probes), len(part), sorted(bounds)))

for b in bad:
    print("FAIL|" + b)
PY
)" || { fail "rules file is not valid JSON or has an unexpected shape"; OUT=""; }

while IFS='|' read -r verdict msg; do
  [ -z "$verdict" ] && continue
  case "$verdict" in
    OK)   pass "$msg" ;;
    FAIL) fail "$msg" ;;
  esac
done <<< "$OUT"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "mail filter-views partition: PASS"; exit 0
else
  echo "mail filter-views partition: FAIL"; exit 1
fi
