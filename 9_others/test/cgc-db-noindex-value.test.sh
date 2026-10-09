#!/bin/sh
# #888 — files with no search value must not be indexable work.
#
# cloud-u-android needs several 2h octocode windows to converge, so every file in
# its indexable set costs embedding time on every first pass. Lockfiles
# (flake.lock, Cargo.lock, Gemfile.lock, bun.lock, pubspec.lock, go.sum), Gradle's
# dependency verification metadata, the Gradle wrapper boilerplate copied into
# every app, sqldelight/Room schema dumps (*.db, binary SQLite) and Tauri's
# generated android/ios projects (src-tauri/gen/) were all still indexable at
# cloud-u-android 2026-10-09 after the earlier noindex pass. Source, build
# scripts, version catalogs, manifests and docs must stay.
#
# The patterns are replayed through the planner's own chunk_indexable() (git's
# gitignore engine, the syntax octocode's .noindex uses) against real-shaped
# paths: a pattern that is declared but does not match is a fail-green.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

for c in "$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json" \
         "$ROOT/../cloud-u-containers/user-ai_cloud-cgc-pub-mcp/build.json"; do
  [ -f "$c" ] && { BJ=$c; break; }
done
[ -n "${BJ:-}" ] || { echo "FATAL: cloud-cgc-pub-mcp build.json not found (looked in a_solutions/ and ../cloud-u-containers/)"; exit 1; }
LIB="$ROOT/1_cicd/src/ops/cloud-cgc-db-chunk.sh"
[ -f "$LIB" ] || { echo "FATAL: chunk library not found at $LIB"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
R="$T/repo"; mkdir -p "$R"
git init -q "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" config maintenance.auto false; git -C "$R" config gc.auto 0

# Junk: must NOT be indexable.
cat > "$T/junk" <<'EOF'
aa_cloud-superapp/flake.lock
ac_cloud-notes/Cargo.lock
ac_cloud-chat/Gemfile.lock
ac_cloud-code/bun.lock
ab_cloud-libs-shared/libs/gitsync/rust_builder/cargokit/build_tool/pubspec.lock
ac_cloud-myterminal/hub/go.sum
ac_cloud-camera/gradle/verification-metadata.xml
ac_cloud-camera/gradlew
ac_cloud-camera/gradlew.bat
ac_cloud-matrix/libraries/session-storage/impl/src/main/sqldelight/databases/1.db
ac_cloud-matrix/libraries/push/impl/src/main/sqldelight/databases/2.db
ac_cloud-c3-webserver/src-tauri/gen/android/app/build.gradle.kts
ac_cloud-c3-webserver/src-tauri/gen/schemas/desktop-schema.json
ac_cloud-code/package-lock.json
ac_cloud-chat/app/screens/home.test.tsx
ac_cloud-vault/app/src/main/res/drawable/ic.png
EOF
# Value: must stay indexable.
cat > "$T/keep" <<'EOF'
ac_cloud-camera/app/src/main/java/com/cloud/camera/MainActivity.kt
ac_cloud-camera/app/build.gradle.kts
ac_cloud-camera/settings.gradle.kts
ac_cloud-camera/gradle.properties
ac_cloud-camera/gradle/libs.versions.toml
ac_cloud-camera/gradle/wrapper/gradle-wrapper.properties
ac_cloud-camera/app/src/main/AndroidManifest.xml
ac_cloud-notes/Cargo.toml
ac_cloud-myterminal/hub/go.mod
ac_cloud-myterminal/hub/main.go
aa_cloud-superapp/flake.nix
ac_cloud-matrix/libraries/session-storage/impl/src/main/sqldelight/io/element/Session.sq
ac_cloud-c3-webserver/src-tauri/src/main.rs
ac_cloud-c3-webserver/src-tauri/Cargo.toml
ac_cloud-c3-webserver/src-tauri/tauri.conf.json
ac_cloud-code/src/index.ts
ac_cloud-code/package.json
ac_cloud-chat/Gemfile
README.md
1_cicd/src/build.sh
EOF
while IFS= read -r p; do
  mkdir -p "$R/$(dirname "$p")"; echo x > "$R/$p"
done < "$T/junk"
while IFS= read -r p; do
  mkdir -p "$R/$(dirname "$p")"; echo x > "$R/$p"
done < "$T/keep"

# The .noindex cloud-cgc-db-update.sh writes for cloud-u-android: base + per-repo extra.
{ jq -r '.runtime.octocode.noindex_patterns // [] | .[]' "$BJ"
  jq -r '((.runtime.octocode.noindex_extra // {})["cloud-u-android"] // []) | .[]' "$BJ"; } > "$R/.noindex"
git -C "$R" add -A && git -C "$R" commit -qm fixture

# shellcheck disable=SC1090
. "$LIB"
chunk_indexable "$R" > "$T/indexable"

pass=0; fail=0
while IFS= read -r p; do
  if grep -qxF "$p" "$T/indexable"; then fail=$((fail+1)); echo "  FAIL still indexable (no search value): $p"
  else pass=$((pass+1)); echo "  ok   excluded  $p"; fi
done < "$T/junk"
while IFS= read -r p; do
  if grep -qxF "$p" "$T/indexable"; then pass=$((pass+1)); echo "  ok   kept      $p"
  else fail=$((fail+1)); echo "  FAIL excluded but has search value: $p"; fi
done < "$T/keep"

echo "cgc-db-noindex-value: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
