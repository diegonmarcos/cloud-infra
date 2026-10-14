#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_reconcile_absent_redeploy.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_ship_reconcile_absent_redeploy.sh — the reconcile brings back ONE absent
# service, and only when that is safe.
#
# THE DEFECT UNDER TEST (backlog #986 follow-up)
#
# matomo-hybrid was evicted on 2026-10-10 21:51 by another service's deploy.
# Its compose file, image and secrets stayed on oci-apps, so one
# `docker compose up -d` was the whole repair, yet for three days the reconcile
# only printed "ABSENT — declared but not running". Before
# cloud-ship-reconcile-absent-redeploy.sh nothing acted on `absent` at all.
#
# Drives the real script with its three impure operations injected (the VM, the
# GitHub restore check, the alert), so it needs no fleet and no network:
#   1. dry-run acts on nothing and names what it would do
#   2. apply brings up exactly ONE service even when two are eligible
#   3. only `absent` findings are candidates (drift/created/stopped ignored)
#   4. excluded services, never-deployed projects, uncached images and port
#      clashes are skipped — the last two with an alert naming why
#   5. never during a cgc-db restore: GitHub run in progress, GitHub
#      unreadable, or the restore script running on the VM -> nothing touched
#   6. a redeploy whose container does not come up exits 1 and alerts
#   7. the compose command is `up -d --no-recreate --no-build --pull never`
#      — never down, rm, pull or a full `config` dump
#   8. disabled in config -> nothing
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-reconcile-absent-redeploy.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }

pass=0; fail=0
ck() {
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Fixtures: four services on one VM ─────────────────────────────────────
mk() {   # mk <dir> <container> <port> [one_shot]
  mkdir -p "$WORK/sol/$1"
  jq -n --arg c "$2" --arg p "$3" --arg rp "/opt/containers/$1" '
    { deploy: { host: "testvm", remote_path: $rp },
      ports: (if $p == "" then {} else { app: ($p | tonumber) } end),
      containers: { app: { container_name: $c } } }' > "$WORK/sol/$1/build.json"
}
mk infra-obs_matomo      matomo-hybrid   8080
mk infra-ai_jev-sidecar  jev-sidecar     3110
mk user-prod_second      second-app      3999
mk infra-bld_gha-runner  gha-runner      ""

base_config() {
  jq -n '{ reship_classes: ["drift","created"], max_reships_per_run: 5,
           absent_redeploy: { enabled: true, settle_seconds: 0,
             exclude: { "infra-bld_gha-runner": "on-demand runner" },
             ntfy: { vm: "testvm", url: "http://ntfy.invalid", topic: "t" } } }'
}
base_config > "$WORK/config.json"

# The VM. State per service lives in files the test edits between cases:
#   $WORK/vm/<remote basename>/{compose,manifest,missing,holders}
# Every script the VM is asked to run is logged, and `up` scripts are counted.
cat > "$WORK/remote" <<STUB
#!/usr/bin/env bash
s="\$(cat)"
printf '%s\n----\n' "\$s" >> "$WORK/remote.log"
rp="\$(printf '%s\n' "\$s" | sed -n 's/^RP=//p' | head -1)"
rp="\$(eval "printf '%s' \$rp")"
d="$WORK/vm/\$(basename "\$rp")"
case "\$s" in
  "# absent-redeploy:preflight"*)
    echo "RESTORE=\$(cat "$WORK/vm/restore" 2>/dev/null || echo 0)"
    [ -f "\$d/compose" ] || { echo "COMPOSE=none"; exit 0; }
    echo "COMPOSE=compose/docker-compose.yml"
    [ -f "\$d/manifest" ] && echo MANIFEST=yes || echo MANIFEST=no
    echo "IMAGES_MISSING=\$(cat "\$d/missing" 2>/dev/null)"
    echo "PORT_HOLDERS=\$(cat "\$d/holders" 2>/dev/null)" ;;
  "# absent-redeploy:up"*)
    echo "\$(basename "\$rp")" >> "$WORK/ups"
    echo "  compose: Container x Started"
    cn="\$(printf '%s\n' "\$s" | sed -n 's/^CNAMES=//p' | head -1)"
    echo "STATE \$cn \$(cat "\$d/after" 2>/dev/null || echo running)"
    echo "UP_RC=0" ;;
esac
STUB
chmod +x "$WORK/remote"
printf '#!/bin/sh\ncat "%s/restore_runs"\n' "$WORK" > "$WORK/runs"; chmod +x "$WORK/runs"
printf '#!/bin/sh\necho "$1" >> "%s/alerts"\n' "$WORK" > "$WORK/notify"; chmod +x "$WORK/notify"

deployed() { mkdir -p "$WORK/vm/$1"; touch "$WORK/vm/$1/compose" "$WORK/vm/$1/manifest"; }
reset_vm() {
  rm -rf "$WORK/vm" "$WORK/ups" "$WORK/alerts" "$WORK/remote.log"; mkdir -p "$WORK/vm"
  echo 0 > "$WORK/restore_runs"; echo 0 > "$WORK/vm/restore"
  for s in infra-obs_matomo infra-ai_jev-sidecar user-prod_second infra-bld_gha-runner; do deployed "$s"; done
  base_config > "$WORK/config.json"
}

FINDINGS="$WORK/findings.tsv"
printf 'testvm\tinfra-bld_gha-runner\tabsent\tgha-runner\n'      >  "$FINDINGS"
printf 'testvm\tinfra-obs_matomo\tabsent\tmatomo-hybrid\n'      >> "$FINDINGS"
printf 'testvm\tinfra-obs_matomo\tabsent\tmatomo-hybrid\n'      >> "$FINDINGS"
printf 'testvm\tuser-prod_second\tabsent\tsecond-app\n'        >> "$FINDINGS"
printf 'testvm\tinfra-ai_jev-sidecar\tdrift\tjev-sidecar\n'     >> "$FINDINGS"

run() {   # run <mode> [findings file] -> sets OUT (the stdout line) and RC
  RC=0
  OUT="$(CLOUD_ROOT="$REPO_ROOT" SOLUTIONS_DIR="$WORK/sol" RESHIP_CONFIG="$WORK/config.json" \
         ABSENT_REMOTE_CMD="$WORK/remote" ABSENT_RESTORE_RUNS_CMD="$WORK/runs" ABSENT_NOTIFY_CMD="$WORK/notify" \
         bash "$SCRIPT" "$1" < "${2:-$FINDINGS}" 2>"$WORK/err")" || RC=$?
}
ups()    { [ -f "$WORK/ups" ] && paste -sd' ' "$WORK/ups" || true; }
alerts() { [ -f "$WORK/alerts" ] && wc -l < "$WORK/alerts" | tr -d ' ' || echo 0; }

echo "== dry run =="
reset_vm
run --dry-run; ck "dry-run names the first eligible absent service" "$OUT" "would-redeploy infra-obs_matomo"
ck "dry-run brings nothing up" "$(ups)" ""
grep -q 'skip infra-bld_gha-runner on testvm — excluded: on-demand runner' "$WORK/err" \
  && ck "excluded service skipped with its reason" ok ok || ck "excluded service skipped with its reason" "$(cat "$WORK/err")" "an excluded line"

echo "== apply: at most one per run =="
reset_vm
run --apply; ck "apply redeploys the first eligible service" "$OUT" "redeployed infra-obs_matomo"
ck "exit 0 when it came up" "$RC" "0"
ck "exactly one compose up although two services are eligible" "$(ups)" "infra-obs_matomo"
ck "a redeploy is announced" "$(alerts)" "1"

echo "== only absent findings are candidates =="
reset_vm
printf 'testvm\tinfra-ai_jev-sidecar\tdrift\tjev-sidecar\ntestvm\tuser-prod_second\tcreated\tsecond-app\ntestvm\tinfra-obs_matomo\tstopped\tmatomo-hybrid\n' > "$WORK/f2"
run --apply "$WORK/f2"; ck "drift/created/stopped are not redeployed here" "$OUT" "none"
ck "and nothing is touched" "$(ups)" ""
ck "no VM call at all" "$([ -f "$WORK/remote.log" ] && echo called || echo none)" "none"

echo "== safety skips =="
reset_vm
echo "wireguard-mesh " > "$WORK/vm/infra-obs_matomo/holders"
run --apply; ck "port held by another container: skip to the next candidate" "$OUT" "redeployed user-prod_second"
ck "the clash is alerted (clash + redeploy)" "$(alerts)" "2"
grep -q 'port :8080 is held by: wireguard-mesh' "$WORK/err" && ck "the alert names the holder" ok ok \
  || ck "the alert names the holder" "$(cat "$WORK/err")" "a line naming wireguard-mesh"

reset_vm
echo "matomo-hybrid " > "$WORK/vm/infra-obs_matomo/holders"
run --apply; ck "our own container on the port is not a clash" "$OUT" "redeployed infra-obs_matomo"

reset_vm
rm -f "$WORK/vm/infra-obs_matomo/manifest" "$WORK/vm/user-prod_second/compose"
run --apply; ck "never-deployed projects are a Ship's job, not ours" "$OUT" "none"
ck "nothing brought up" "$(ups)" ""

reset_vm
echo "ghcr.io/x/matomo-binaries:latest" > "$WORK/vm/infra-obs_matomo/missing"
rm -f "$WORK/vm/user-prod_second/manifest"
run --apply; ck "uncached image: skipped" "$OUT" "none"
ck "uncached image: alerted" "$(alerts)" "1"

echo "== never during a cgc-db restore =="
reset_vm; echo 1 > "$WORK/restore_runs"
run --apply; ck "GitHub restore run in progress: refused" "$OUT" "refused restore-running"
ck "no VM call" "$([ -f "$WORK/remote.log" ] && echo called || echo none)" "none"

reset_vm; printf '#!/bin/sh\nexit 1\n' > "$WORK/runs.fail"; chmod +x "$WORK/runs.fail"
OUT="$(CLOUD_ROOT="$REPO_ROOT" SOLUTIONS_DIR="$WORK/sol" RESHIP_CONFIG="$WORK/config.json" \
       ABSENT_REMOTE_CMD="$WORK/remote" ABSENT_RESTORE_RUNS_CMD="$WORK/runs.fail" ABSENT_NOTIFY_CMD="$WORK/notify" \
       bash "$SCRIPT" --apply < "$FINDINGS" 2>/dev/null)"
ck "GitHub unreadable counts as 'maybe running': refused" "$OUT" "refused restore-unknown"
ck "nothing brought up" "$(ups)" ""

reset_vm; echo 2 > "$WORK/vm/restore"
run --apply; ck "restore script running on the VM (Dagu path): refused" "$OUT" "refused restore-running"
ck "nothing brought up" "$(ups)" ""

echo "== a redeploy that does not come up =="
reset_vm; echo exited > "$WORK/vm/infra-obs_matomo/after"
run --apply; ck "reports the failure" "$OUT" "failed infra-obs_matomo"
ck "exits 1" "$RC" "1"
ck "and stops there (still one attempt per run)" "$(ups)" "infra-obs_matomo"
ck "and alerts" "$(alerts)" "1"

echo "== the compose command itself =="
reset_vm; run --apply
up="$(grep -h 'docker compose' "$WORK/remote.log" | grep ' up ' | head -1)"
case "$up" in *"up -d --no-recreate --no-build --pull never"*) ck "up -d --no-recreate --no-build --pull never" ok ok ;;
                *) ck "up -d --no-recreate --no-build --pull never" "$up" "the bounded up" ;; esac
bad="$(grep -hE 'docker compose[^|]* (down|rm|pull|restart)|docker (rm|stop|kill) ' "$WORK/remote.log" | head -1)"
ck "never down/rm/pull/restart/stop" "$bad" ""
cfg="$(grep -h 'config' "$WORK/remote.log" | grep 'docker compose' | grep -v -- '--images' | head -1)"
ck "compose config only ever with --images (no resolved secrets printed)" "$cfg" ""

echo "== disabled =="
reset_vm; jq '.absent_redeploy.enabled = false' "$WORK/config.json" > "$WORK/c2" && mv "$WORK/c2" "$WORK/config.json"
run --apply; ck "enabled=false does nothing" "$OUT" "none"
ck "no VM call" "$([ -f "$WORK/remote.log" ] && echo called || echo none)" "none"

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass assertions)"; exit 0; fi
echo "FAIL ($fail of $((pass+fail)))"
exit 1
