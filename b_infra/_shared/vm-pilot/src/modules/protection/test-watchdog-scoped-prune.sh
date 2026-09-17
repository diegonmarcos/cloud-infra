#!/bin/sh
# Test #393: the disk-watchdog's docker prunes must be SCOPED, so that automatic
# disk pressure can never delete a declared container, a tagged fleet image, or
# any volume.
#
# WHY this test exists
# ────────────────────
# infra/prune-maintenance.nix carries the scoped filter and the comment explaining
# it. watchdog.nix — its sibling, running every 5 minutes as root — never received
# it. On 2026-09-16 that gap deleted matomo off oci-apps: healthy at
# 2026-09-15T22:39:58Z, then `container prune` took the container at 05:24:46 and
# the CRIT branch untagged matomo-binaries:latest and matomo-configs:latest at
# 06:30:21. It freed 22.44MB against a ~19GB shortfall.
#
# protection/guardrails.nix already BLOCKS these operations — but only as a PATH
# wrapper in ~/.local/bin, which a root systemd unit never traverses. So the ban
# has to be asserted against this source file directly. That is this test.
#
# Run:  sh test-watchdog-scoped-prune.sh
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/watchdog.nix"
SIB="$(cd "$(dirname "$0")" && pwd)/../infra/prune-maintenance.nix"
fail=0
ok()   { printf "  [ok] %s\n"   "$1"; }
nope() { printf "  [FAIL] %s\n" "$1"; fail=1; }

echo "test-watchdog-scoped-prune: $SRC"

# Only the actual prune command lines matter. Every rationale comment in this
# module quotes the banned flags by name, and matching those would make the test
# pass or fail on prose. Strip comments first, then assert against code only.
CODE=$(sed 's/[[:space:]]*#.*$//' "$SRC")

# ── 1. No unscoped `container prune` ──────────────────────────────────
# A bare `docker container prune -f` takes every stopped container, declared or not.
if printf '%s\n' "$CODE" | grep -q 'docker container prune' \
   && ! printf '%s\n' "$CODE" | grep 'docker container prune' \
        | grep -q 'label!=com.docker.compose.project'; then
    nope "container prune is present but NOT filtered on label!=com.docker.compose.project"
else
    ok "container prune is absent or label-scoped"
fi

# ── 2. No volume pruning anywhere on the automatic path ───────────────
# Volumes are the databases. There is no safe automatic form of this.
if printf '%s\n' "$CODE" | grep -qE 'docker[[:space:]]+volume[[:space:]]+(prune|rm)'; then
    nope "watchdog still prunes/removes docker volumes — databases live there"
else
    ok "no docker volume prune/rm on the automatic path"
fi

# ── 3. No `image prune -a` — `-a` drops TAGGED images ─────────────────
# Matches -a, -af, -fa and --all. Dangling-only pruning (no -a) is fine.
if printf '%s\n' "$CODE" | grep 'docker image prune' \
     | grep -qE '(^|[[:space:]])-(-all|[a-z]*a[a-z]*)([[:space:]]|$)'; then
    nope "image prune uses -a/--all — that deletes TAGGED fleet deploy artifacts"
else
    ok "image prune is dangling-only (no -a/--all)"
fi

# ── 4. No `docker system prune` ───────────────────────────────────────
# Its container sweep cannot be scoped as tightly as the label filter, so it
# silently re-opens the hole check 1 closes.
if printf '%s\n' "$CODE" | grep -q 'docker system prune'; then
    nope "docker system prune is back — it re-opens the unscoped container sweep"
else
    ok "no docker system prune"
fi

# ── 5. CRIT must still be able to free something ──────────────────────
# A watchdog that can no longer reclaim anything is also a failure. Builder
# cache is pure derived data and is the safe aggressive lever.
if printf '%s\n' "$CODE" | grep -q 'docker builder prune -af'; then
    ok "CRIT retains an aggressive but safe lever (builder prune -af)"
else
    nope "CRIT has no aggressive reclaim left — builder prune -af is missing"
fi

# ── 6. The sibling this was copied from must still carry the pattern ──
# If prune-maintenance.nix ever loses the filter, this module's comments point
# at a pattern that no longer exists and the next agent re-invents a second one.
if grep -q 'label!=com.docker.compose.project' "$SIB"; then
    ok "sibling infra/prune-maintenance.nix still carries the reference pattern"
else
    nope "sibling infra/prune-maintenance.nix lost the label filter"
fi

# ── 7. No stale docker flag — --keep-storage is deprecated, --max-storage is rejected ──
# Verified against the live oci-apps docker (27.5.1) on 2026-09-17:
#   --keep-storage    still parses but warns "Flag --keep-storage has been
#                     deprecated ... changed to max-storage"
#   --max-storage     "unknown flag" — rejected outright
#   --max-used-space  current flag ("Maximum amount of disk space allowed to
#                     keep for cache") — the same 1G-keeper as --keep-storage=1G
if printf '%s\n' "$CODE" | grep -qE '\-\-keep-storage|\-\-max-storage'; then
    nope "builder prune passes a stale flag (--keep-storage or --max-storage) — the current one is --max-used-space"
else
    ok "no stale builder-prune flag (--keep-storage/--max-storage)"
fi
if printf '%s\n' "$CODE" | grep -q '\-\-max-used-space'; then
    ok "builder prune uses the current --max-used-space"
else
    nope "builder prune does not pass --max-used-space — the 1G build-cache cap is gone"
fi

# ── 8. The watchdog keeps a durable action log OUTSIDE the journal ──
# journalctl --vacuum erases the journal, which was the only record of what the
# watchdog deleted and why (on oci-apps 2026-09-16 it ate 16 days, including
# the run that had just reclaimed 12.13GB). #447: every deletion appends to
# WATCHDOG_LOG, which the vacuum cannot reach.
if printf '%s\n' "$CODE" | grep -q 'WATCHDOG_LOG='; then
    ok "durable action log defined (WATCHDOG_LOG)"
else
    nope "no WATCHDOG_LOG — the journal vacuum would erase the watchdog's own action record"
fi
# The directive must be Nix-escaped in this source file (''$ before the brace):
# a bare ${ would be parsed as Nix interpolation and would break the entire
# watchdog module at eval time — a latent build error, not a runtime one.
if printf '%s\n' "$CODE" | grep -q "WATCHDOG_LOG=''\${"; then
    ok "WATCHDOG_LOG is Nix-escaped (double single-quote before the brace) — the module still evaluates"
else
    nope "WATCHDOG_LOG uses a bare dollar-brace in nix source — Nix interpolation breaks the module eval"
fi

# ── 9. Every journal vacuum is paired with a record call ──
# The vacuum is the one deletion that erases its own evidence; each must be
# mirrored by a record line so the audit survives the vacuum.
_vac_n=$(printf '%s\n' "$CODE" | grep -c 'journalctl --vacuum' || true)
_rec_n=$(printf '%s\n' "$CODE" | grep -c 'record "journal"' || true)
if [ "$_vac_n" -gt 0 ] && [ "$_vac_n" -eq "$_rec_n" ]; then
    ok "all $_vac_n journal vacuums are paired with a record call"
else
    nope "journal vacuums ($_vac_n) vs journal record calls ($_rec_n) are out of balance"
fi

echo
[ "$fail" -eq 0 ] && echo "test-watchdog-scoped-prune: PASS" && exit 0
echo "test-watchdog-scoped-prune: FAIL"
exit 1
