#!/usr/bin/env bash
# Leak-scan gates — mutation-tested: a planted FAKE JWT must turn each gate red,
# and removing it must turn it green again.
#
#   G1  .githooks/leak-scan --files      (the scanner, whole files)
#   G2  .githooks/leak-scan --staged     (pre-commit, added lines only)
#   G3  step_verify_dist_leaks           (container engine, wrangler dist/)
#   G4  gitleaks with the same rules     (CI workflow) — when gitleaks is on PATH
#   G5  fleet emitter: gates land in PUBLIC repos only
#   G6  the real declaration is complete and wired
#
# The fake token is assembled at runtime from base64 pieces, so this file never
# holds a token-shaped literal (it would trip the very gates it tests).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCAN="$ROOT/0_apps/src/githooks/leak-scan"
RULES="$ROOT/0_apps/src/root/gitleaks.toml"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-verify-dist-leaks.sh"
FLEET="$ROOT/9_others/src/deploy-dotfiles-fleet.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
rc()  { "$@" >/dev/null 2>&1; echo $?; }

b64u() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
FAKE="$(b64u '{"alg":"none","typ":"JWT"}').$(b64u '{"sub":"leak-scan-mutation","iss":"fixture"}').$(b64u 'fake-signature-not-a-secret')"
gitq() { git -c user.name=t -c user.email=t@invalid -c core.hooksPath=/dev/null "$@"; }

# ── G1 scanner over files ─────────────────────────────────────────────────
R="$T/repo"; mkdir -p "$R/svc/dist"; gitq init -q "$R"; cp "$RULES" "$R/.gitleaks.toml"
printf 'name = "worker"\n[vars]\nGOOGLE_EMAIL = "a@example.invalid"\n' > "$R/svc/dist/wrangler.toml"
[ "$(cd "$R" && rc sh "$SCAN" --files svc/dist/wrangler.toml)" = 0 ] && ok "G1a clean wrangler.toml passes" || bad "G1a clean file flagged"
printf 'C3_BEARER_TOKEN = "%s"\n' "$FAKE" >> "$R/svc/dist/wrangler.toml"
out="$(cd "$R" && sh "$SCAN" --files svc/dist/wrangler.toml 2>&1)"; r=$?
[ "$r" = 1 ] && grep -q 'token-shape-jwt.*svc/dist/wrangler.toml' <<<"$out" && ok "G1b planted JWT → RED (exit 1, names file + rule)" || bad "G1b planted JWT not caught (exit $r)"
grep -qF "$FAKE" <<<"$out" && bad "G1c scanner ECHOED the value" || ok "G1c value never printed"
sed -i '/C3_BEARER_TOKEN/d' "$R/svc/dist/wrangler.toml"
[ "$(cd "$R" && rc sh "$SCAN" --files svc/dist/wrangler.toml)" = 0 ] && ok "G1d removed → GREEN" || bad "G1d still red after removal"
printf 'PEM = "x" # %s%s\n' "-----BEGIN RSA PRIV" "ATE KEY-----" > "$R/k.txt"   # split: this file must not hold the shape itself
[ "$(cd "$R" && rc sh "$SCAN" --files k.txt)" = 1 ] && ok "G1e PEM private-key header → RED" || bad "G1e PEM header missed"
printf 'X_TOKEN = "%s" # gitleaks:allow\n' "$FAKE" > "$R/k.txt"
[ "$(cd "$R" && rc sh "$SCAN" --files k.txt)" = 0 ] && ok "G1f gitleaks:allow honoured" || bad "G1f gitleaks:allow ignored"
rm -f "$R/k.txt"
printf '[[rules]]\nid = "x"\n' > "$T/norules.toml"
[ "$(cd "$R" && LEAK_SCAN_CONFIG="$T/norules.toml" rc sh "$SCAN" --files svc/dist/wrangler.toml)" = 2 ] && ok "G1g no token-shape rules → refuses to report clean (exit 2)" || bad "G1g empty rule set reported clean"

# ── G2 pre-commit (staged) ────────────────────────────────────────────────
( cd "$R" && gitq add .gitleaks.toml svc && gitq commit -qm base )
printf 'API_TOKEN = "%s"\n' "$FAKE" > "$R/svc/new.env"; ( cd "$R" && gitq add svc/new.env )
[ "$(cd "$R" && PATH="/usr/bin:/bin" rc sh "$SCAN" --staged)" = 1 ] && ok "G2a staged JWT → commit REFUSED (grep path, no gitleaks)" || bad "G2a staged JWT allowed"
( cd "$R" && gitq rm -q --cached svc/new.env ); rm -f "$R/svc/new.env"
echo 'plain = 1' > "$R/svc/ok.txt"; ( cd "$R" && gitq add svc/ok.txt )
[ "$(cd "$R" && PATH="/usr/bin:/bin" rc sh "$SCAN" --staged)" = 0 ] && ok "G2b clean staged change → allowed" || bad "G2b clean change refused"

# ── G3 container-engine dist gate ─────────────────────────────────────────
log() { :; }; log_error() { echo "ERR $*" >&2; }
STEPS_DIR="$ROOT/1_cicd/src/scripts"; SERVICE_NAME=cloudflare-worker
# shellcheck disable=SC1090
. "$STEP"
SVC="$R/svc"; DIST_DIR="$SVC/dist"; printf '.secrets\n.wrangler/\n' > "$SVC/.gitignore"
WRANGLER_DEPLOY=true
[ "$(rc step_verify_dist_leaks)" = 0 ] && ok "G3a clean worker dist → build passes" || bad "G3a clean dist refused"
printf 'C3_BEARER_TOKEN = "%s"\n' "$FAKE" >> "$DIST_DIR/wrangler.toml"
[ "$(rc step_verify_dist_leaks)" = 1 ] && ok "G3b JWT in dist/wrangler.toml → build FAILS" || bad "G3b dist leak not caught"
sed -i '/C3_BEARER_TOKEN/d' "$DIST_DIR/wrangler.toml"
printf 'C3_BEARER_TOKEN=%s\n' "$FAKE" > "$DIST_DIR/.secrets"; mkdir -p "$DIST_DIR/.wrangler/tmp"; printf 'x="%s"\n' "$FAKE" > "$DIST_DIR/.wrangler/tmp/b.js"
[ "$(rc step_verify_dist_leaks)" = 0 ] && ok "G3c gitignored dist/.secrets + .wrangler/ are where secrets belong → not scanned" || bad "G3c ignored secrets file failed the build"
cp "$DIST_DIR/.secrets" "$DIST_DIR/vars.txt"; ( cd "$R" && gitq add -f svc/dist/vars.txt ) # tracked → never ignored
[ "$(rc step_verify_dist_leaks)" = 1 ] && ok "G3d a TRACKED dist file is scanned even if a pattern would ignore it" || bad "G3d tracked dist file skipped"
WRANGLER_DEPLOY=false
[ "$(rc step_verify_dist_leaks)" = 0 ] && ok "G3e non-wrangler service untouched (deploy.wrangler gates the step)" || bad "G3e ran on a non-wrangler service"

# ── G4 gitleaks itself, same rules (the CI gate) ──────────────────────────
if command -v gitleaks >/dev/null 2>&1; then
    G="$T/gl"; gitq init -q "$G"; cp "$RULES" "$G/.gitleaks.toml"; echo a > "$G/a"; ( cd "$G" && gitq add -- a .gitleaks.toml && gitq commit -qm a )
    [ "$(cd "$G" && rc gitleaks git -c .gitleaks.toml --log-opts=-1 --no-banner --exit-code 1 .)" = 0 ] && ok "G4a clean commit → CI green" || bad "G4a clean commit red"
    printf 'C3_BEARER_TOKEN = "%s"\n' "$FAKE" > "$G/wrangler.toml"; ( cd "$G" && gitq add -- wrangler.toml && gitq commit -qm b )
    [ "$(cd "$G" && rc gitleaks git -c .gitleaks.toml --log-opts=-1 --no-banner --exit-code 1 .)" = 1 ] && ok "G4b planted JWT commit → CI RED" || bad "G4b gitleaks missed planted JWT"
else
    echo "SKIP G4 gitleaks not on PATH (CI workflow runs it; leak-scan.yml mutation=plant proves it there)"
fi

# ── G5 fleet emitter: public repos only ───────────────────────────────────
S="$T/fsrc"; D="$T/fdist"; B="$T/fbase"; mkdir -p "$S" "$D/githooks" "$D/github/workflows" "$D/root" "$B/pub" "$B/priv"
cp "$SCAN" "$D/githooks/leak-scan"; echo 'name: x' > "$D/github/workflows/leak-scan.yml"; cp "$RULES" "$D/root/gitleaks.toml"; echo '{}' > "$D/root/mcp.json"
gitq init -q "$B/pub"; gitq init -q "$B/priv"
cat > "$S/manifest.json" <<'J'
{"targets":{},"root_targets":{"mcp.json":".mcp.json"},
 "public_targets":{"githooks":".githooks","github":".github"},"public_root_targets":{"gitleaks.toml":".gitleaks.toml"},
 "fleet":{"repos":[{"dir":"pub","private":false},{"dir":"priv","private":true}],"root_files":["mcp.json"]}}
J
out="$(sh "$FLEET" --check "$S" "$D" "$B" 2>&1)"
grep -q 'MISSING.*pub.*\.gitleaks\.toml' <<<"$out" && grep -q 'MISSING.*pub.*\.github/workflows/leak-scan\.yml' <<<"$out" && ok "G5a --check: public repo without the gates is DRIFT" || bad "G5a public repo lacking gates not flagged"
grep -qE 'priv.*(gitleaks|leak-scan)' <<<"$out" && bad "G5b private repo was asked to carry gates" || ok "G5b private repo never gets gates"
sh "$FLEET" "$S" "$D" "$B" >/dev/null 2>&1
[ -x "$B/pub/.githooks/leak-scan" ] && [ -f "$B/pub/.gitleaks.toml" ] && [ -f "$B/pub/.github/workflows/leak-scan.yml" ] && ok "G5c emit writes all gates into the public repo (exec bit kept)" || bad "G5c emit incomplete"
[ ! -e "$B/priv/.gitleaks.toml" ] && [ ! -e "$B/priv/.githooks" ] && ok "G5d emit leaves the private repo alone" || bad "G5d emit leaked gates into private repo"
[ "$(git -C "$B/pub" config core.hooksPath)" = .githooks ] && [ -z "$(git -C "$B/priv" config core.hooksPath)" ] && ok "G5e hooksPath wired only where unset and public" || bad "G5e hooksPath wiring wrong"
[ "$(rc sh "$FLEET" --check "$S" "$D" "$B")" = 0 ] && ok "G5f second --check is GREEN" || bad "G5f still drifting after emit"

# ── G6 real declaration ───────────────────────────────────────────────────
M="$ROOT/0_apps/src/manifest.json"
jq -e '.public_targets.githooks==".githooks" and .public_targets.github==".github" and .public_root_targets["gitleaks.toml"]==".gitleaks.toml"' "$M" >/dev/null && ok "G6a manifest declares the three gates as public_*" || bad "G6a manifest public_* incomplete"
[ -x "$ROOT/0_apps/src/githooks/leak-scan" ] && [ -x "$ROOT/0_apps/src/githooks/pre-commit" ] && [ -f "$ROOT/0_apps/src/github/workflows/leak-scan.yml" ] && ok "G6b gate sources exist, hooks executable" || bad "G6b gate sources missing / not executable"
n=$(grep -c '^id = "token-shape-' "$RULES"); [ "$n" -ge 4 ] && ok "G6c $n token-shape rules declared" || bad "G6c token-shape rules missing ($n)"
grep -q 'step_verify_dist_leaks; step_wrangler' "$ROOT/1_cicd/src/scripts/cloud-ship-container-engine.sh" && ok "G6d engine runs the dist gate before every wrangler deploy" || bad "G6d dist gate not wired before step_wrangler"
grep -q '\.githooks/leak-scan" --staged' "$ROOT/0_git/src/hooks/pre-commit" && ok "G6e cloud-infra's own pre-commit chains the leak scan" || bad "G6e 0_git pre-commit does not chain leak-scan"

echo "leak-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
