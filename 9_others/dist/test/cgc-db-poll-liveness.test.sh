#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-poll-liveness.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# The restore poll decides "still working" vs "died" from one round trip that
# returns two facts glued with '@': the rc file's contents (empty while running)
# and a process count. Getting that split wrong is silent -- the loop would read
# a live restore as finished, or a flaky ssh as a crash -- so it gets a test.
#
# Mirrors the parsing in 1_cicd/src/cicd/cgc-db-index.yml (restore-all poll).
set -u
FAIL=0
ck() { # ck <label> <OUT> <want_rc> <want_alive>
  OUT=$2
  RC=$(printf '%s' "${OUT%%@*}" | tr -d ' \n')
  ALIVE=$(printf '%s' "${OUT##*@}" | tr -d ' \n')
  if [ "$RC" = "$3" ] && [ "$ALIVE" = "$4" ]; then
    echo "  ok   $1 (rc='$RC' alive='$ALIVE')"
  else
    echo "  FAIL $1: got rc='$RC' alive='$ALIVE', want rc='$3' alive='$4'"
    FAIL=$((FAIL + 1))
  fi
}
echo "== cgc-db restore poll: rc/liveness split"
ck "running: no rc, two procs"      "$(printf '@\n2')"      ""  "2"
ck "finished ok: rc=0"              "$(printf '0\n@\n2')"   "0" "2"
ck "finished bad: rc=1"             "$(printf '1\n@\n0')"   "1" "0"
ck "ssh failed: unknown, not dead"  "@?"                    ""  "?"
ck "died: no rc, no procs"          "$(printf '@\n0')"      ""  "0"

# The GONE counter must need three consecutive zeros, so one flaky poll in the
# middle of a healthy restore cannot end it.
echo "== GONE debounce"
GONE=0; TRIP=0
for A in 0 ? 0 0 2 0 0; do
  if [ "$A" = "0" ]; then GONE=$((GONE + 1)); else GONE=0; fi
  [ "$GONE" -ge 3 ] && TRIP=1
done
if [ "$TRIP" = "0" ]; then echo "  ok   no false trip on 0,?,0,0,2,0,0"; else echo "  FAIL false trip"; FAIL=$((FAIL + 1)); fi
GONE=0; TRIP=0
for A in 2 0 0 0; do
  if [ "$A" = "0" ]; then GONE=$((GONE + 1)); else GONE=0; fi
  [ "$GONE" -ge 3 ] && TRIP=1
done
if [ "$TRIP" = "1" ]; then echo "  ok   trips on three consecutive zeros"; else echo "  FAIL missed real death"; FAIL=$((FAIL + 1)); fi

# The '[c]gc' bracket must not match the poll's own remote command line, which
# contains that pattern literally.
echo "== self-match guard"
if printf '%s\n' "cat /tmp/cgc-restore-pub.rc; ps -o args | grep -c '[c]gc-restore-all.sh'" \
   | grep -q 'cgc-restore-all\.sh'; then
  echo "  FAIL poll command line matches its own pattern"; FAIL=$((FAIL + 1))
else
  echo "  ok   poll command line does not self-match"
fi

[ "$FAIL" = "0" ] && echo "PASS" || echo "FAIL ($FAIL)"
exit "$FAIL"
