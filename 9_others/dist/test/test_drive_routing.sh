#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_drive_routing.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_drive_routing.sh — cloud-drive-mcp: routing table integrity + the two
# pure functions that decide where bytes go.
#
# The drive façade is data-driven: a typo in build.json's routing table is a
# runtime 404, not a build error. These assertions are the thing that fails
# instead. Everything here is dependency-free — no node_modules required.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SOL="$ROOT/a_solutions/infra-api_cloud-drive-mcp"
BUILD="$SOL/build.json"
MCP="$SOL/src/code/mcp"

pass=0
fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
nope() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (expected '$3', got '$2')"; fi; }

echo "== drive routing table =="

[ -f "$BUILD" ] || { echo "FAIL: $BUILD missing"; exit 1; }

# 1. Every method names a backend that is actually declared.
orphan=$(jq -r '.drive as $d
  | [ $d.methods | to_entries[]
      | .key as $k | .value.backend as $b
      | select($d.backends | has($b) | not)
      | $k ] | join(",")' "$BUILD")
check "every method names a declared backend" "$orphan" ""

# 2. Every backend kind is one the dispatcher in drive.ts understands.
badkind=$(jq -r '[.drive.backends | to_entries[]
  | select(.value.kind as $k | ["http","s3","local"] | index($k) | not)
  | .key] | join(",")' "$BUILD")
check "every backend kind is http|s3|local" "$badkind" ""

# 3. http methods carry a path; non-http methods carry an op. Getting this
#    wrong sends an undefined path or an undefined op at the backend.
noroute=$(jq -r '.drive as $d
  | [ $d.methods | to_entries[]
      | .key as $k | .value as $m
      | ($d.backends[$m.backend].kind) as $kind
      | select( ($kind == "http" and (($m.path // "") == ""))
             or ($kind != "http" and (($m.op   // "") == "")) )
      | $k ] | join(",")' "$BUILD")
check "http methods have a path, others have an op" "$noroute" ""

# 4. Destructive methods are flagged, so the tool can say so in help.
destr=$(jq -r '[.drive.methods | to_entries[]
  | select(.value.destructive == true) | .key] | sort | join(",")' "$BUILD")
check "delete methods are flagged destructive" "$destr" "file.delete,s3.delete"

# 5. The container spec and the routing table agree on the port.
check "build.json port matches container port" \
  "$(jq -r '.ports.app' "$BUILD")" "$(jq -r '.containers.app.port' "$BUILD")"

# 6. Identity invariant: client key == service name == container name == image.
name=$(jq -r '.name' "$BUILD")
check "docker.image == name"     "$(jq -r '.docker.image' "$BUILD")"          "$name"
check "container_name == name"   "$(jq -r '.containers.app.container_name' "$BUILD")" "$name"

echo "== pure functions =="

node_out=$(node --experimental-strip-types --input-type=module -e "
import { fillPath } from '$MCP/request.ts';
import { toolFor }  from '$MCP/backends/convert.ts';

let p = 0, f = 0;
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { p++; console.log('  ok   ' + label); }
  else { f++; console.log('  FAIL ' + label + ' (expected ' + w + ', got ' + g + ')'); }
};

// fillPath: the placeholder is filled and the key is CONSUMED — if it leaked
// into rest it would be re-sent as a bogus query param.
let r = fillPath('/repos/{owner}/{repo}', { owner: 'me', repo: 'cloud', limit: 5 });
eq('fills placeholders', r.path, '/repos/me/cloud');
eq('consumed keys leave rest', r.rest, { limit: 5 });
eq('nothing missing', r.missing, []);

// A path param that is absent must be reported, never silently empty.
r = fillPath('/repos/{owner}/{repo}', { owner: 'me' });
eq('missing param reported', r.missing, ['repo']);

// filebrowser paths are nested, so '/' must survive as a separator while each
// segment is still escaped.
r = fillPath('/resources/{path}', { path: 'a b/c d' });
eq('slash survives, segments escaped', r.path, '/resources/a%20b/c%20d');

// A '?' in a value must not open a query string, and '#' must not truncate.
r = fillPath('/resources/{path}', { path: 'x?a=1#f' });
eq('query/fragment chars escaped', r.path, '/resources/x%3Fa%3D1%23f');

// toolFor: gif is in BOTH the image and A/V tables — image→image must win,
// or every png→gif would be handed to ffmpeg.
eq('png -> gif is imagemagick', toolFor('png','gif'), 'convert');
eq('mp4 -> gif is ffmpeg',      toolFor('mp4','gif'), 'ffmpeg');
eq('md  -> pdf is pandoc',      toolFor('md','pdf'),  'pandoc');
eq('png -> jpg is imagemagick', toolFor('png','jpg'), 'convert');
eq('unsupported pair is null',  toolFor('xyz','abc'), null);

console.log('NODE ' + p + ' passed, ' + f + ' failed');
process.exit(f === 0 ? 0 : 1);
" 2>&1)
node_rc=$?   # captured BEFORE any pipe, so a node failure actually fails the test
echo "$node_out" | /run/current-system/sw/bin/grep -vE '^\(node:|ExperimentalWarning|Use \`node'

echo
if [ "$fail" -eq 0 ] && [ "$node_rc" -eq 0 ]; then
  echo "PASS ($pass shell assertions + node checks)"
  exit 0
fi
echo "FAIL ($fail shell failures, node rc=$node_rc)"
exit 1
