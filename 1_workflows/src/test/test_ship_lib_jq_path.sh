#!/usr/bin/env bash
# Phase #19 test: cloud-ship-lib.sh must repair PATH so jq is available when
# invoked via `docker compose run` (non-interactive bash, no /etc/profile).
#
# Proves: if jq is missing from the initial PATH but lives under the HM profile,
# lib.sh adds it; if jq is truly absent everywhere, lib.sh exits 1 loudly instead
# of silently continuing (which was the 2026-04-22 gcp-proxy HM ship failure).
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/cloud-ship-lib.sh"
[ -f "$LIB" ] || { echo "[test] cloud-ship-lib.sh not found at $LIB" >&2; exit 1; }

fail=0
ok()   { printf "  [ok]   %s\n" "$1"; }
nope() { printf "  [FAIL] %s\n" "$1"; fail=1; }

# 1. The shim block must be present and come BEFORE any jq invocation.
if grep -q '^if ! command -v jq' "$LIB"; then
    ok "PATH-repair block present"
else
    nope "PATH-repair block missing"
fi

shim_line=$(grep -n '^if ! command -v jq' "$LIB" | head -1 | cut -d: -f1)
first_jq_line=$(grep -n '^ENGINE_FOLDER=.*jq ' "$LIB" | head -1 | cut -d: -f1)
if [ -n "$shim_line" ] && [ -n "$first_jq_line" ] && [ "$shim_line" -lt "$first_jq_line" ]; then
    ok "repair runs before first jq invocation (line $shim_line < $first_jq_line)"
else
    nope "shim not positioned before first jq call (shim=$shim_line, jq=$first_jq_line)"
fi

# 2. Simulate missing jq + HM profile containing jq → repair must succeed.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/hm/home-path/bin"
# Stub jq that simply prints its args
cat > "$tmp/hm/home-path/bin/jq" <<'JQ'
#!/bin/sh
echo "STUB-JQ:$*"
JQ
chmod +x "$tmp/hm/home-path/bin/jq"

# Provide a dummy config.json so lib.sh doesn't abort on missing file
mkdir -p "$tmp/cloud"
echo '{"engine_folder":"_shared","deps":{"install":{}}}' > "$tmp/cloud/config.json"

# Run lib.sh with a stripped PATH; HOME points at our stub profile layout.
# Strip common jq-providing dirs so the shim actually has to do work.
stripped_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/nix-profile/bin$' | grep -v '/home-path/bin$' | tr '\n' ':')
if env -i PATH="$stripped_path" HOME="$tmp" HOME_STATE_DIR="$tmp/hm" \
    bash -c "
        # fake the HM profile location lib.sh probes
        mkdir -p \"$tmp/.local/state/nix/profiles/home-manager\"
        ln -s \"$tmp/hm\" \"$tmp/.local/state/nix/profiles/home-manager/home-path\" 2>/dev/null || true
        export CLOUD_ROOT=\"$tmp/cloud\"
        . \"$LIB\" >/dev/null 2>&1 || exit 42
        command -v jq >/dev/null
    "; then
    ok "PATH repaired when jq is only under HM home-path"
else
    rc=$?
    if [ "$rc" = "42" ]; then
        nope "lib.sh aborted despite stub jq being reachable under HOME"
    else
        nope "jq still not on PATH after sourcing lib.sh (rc=$rc)"
    fi
fi

# 3. Simulate jq truly missing → lib.sh must exit 1 with a clear message.
#    Build a minimal PATH that has bash/grep/etc but no jq.
rm -rf "$tmp/hm" "$tmp/.local"
min_path=$(mktemp -d)
trap 'rm -rf "$tmp" "$min_path"' EXIT
for _bin in bash sh grep printf command; do
    _real=$(command -v "$_bin" 2>/dev/null) || continue
    ln -sf "$_real" "$min_path/$_bin"
done
set +e
err_output=$(env -i PATH="$min_path" HOME="$tmp" \
    "$min_path/bash" -c "export CLOUD_ROOT=\"$tmp/cloud\"; . \"$LIB\"" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$err_output" | grep -qi "jq not found"; then
    ok "fatal with clear message when jq truly missing (rc=$rc)"
else
    nope "did NOT fatal with clear jq message (rc=$rc, output='$err_output')"
fi

[ "$fail" -eq 0 ] && { echo "[test] ALL CHECKS PASSED"; exit 0; }
echo "[test] FAILED"; exit 1
