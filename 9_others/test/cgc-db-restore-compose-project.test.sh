#!/usr/bin/env bash
# Tester for the compose PROJECT NAME used when restore-all has to recreate a
# missing MCP container (#352).
#
# THE FAILURE IT GUARDS: run 35037956239, job 104674281984. The index was fine,
# the GHCR images were fine, the lance integrity gate passed and the volume swap
# succeeded -- and the restore still ended with cloud-cgc-pub-mcp DOWN and the
# kg-store stale, because the LAST-RESORT RECREATE addressed the wrong compose
# project:
#
#   Error response from daemon: No such container: cloud-cgc-pub-mcp        (x8)
#   [cgc-db-restore-all] ... recreating via compose in /opt/containers/cloud-cgc-pub-mcp/compose
#   warning: volume "octocode_db_pvt" already exists but was created for
#            project "cloud-cgc-pub-mcp" (expected "compose")
#   Error response from daemon: Conflict. The container name "/cloud-cgc-pvt-mcp"
#            is already in use by container "d8aecb71321a...".
#
# Ship creates these containers as `cd $DEPLOY_PATH && docker compose -f
# compose/docker-compose.yml --project-directory . up -d`
# (cloud-ship-container-step-deploy-compose.sh), so the project is
# basename($DEPLOY_PATH). Recreating from inside the compose/ subdir names the
# project "compose" instead; under that foreign name compose cannot see the
# already-running SIBLING container, tries to CREATE it, hits the name conflict,
# and aborts the whole `up` -- so the container that actually needed recreating
# is never created either. deploy-compose.sh's own "Foreign-project container
# eviction" comment names `cd compose && docker compose up` as the way to cause
# exactly this.
#
# So this drives the REAL bring_up() (extracted BY NAME, not re-implemented --
# a re-implementation is how cgc-db-gate.test.sh passed while the path it
# mirrored was wrong) against a stub docker that records argv + cwd, and asserts
# the four properties that were wrong: the project directory, the cwd, the
# compose file path, and the fact that only ONE service is brought up.
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Stub docker: every subcommand fails the way the real box failed (container
# gone), except `compose`, which records how it was called and succeeds.
mkstub() { # $1 = bin dir, $2 = record file
  mkdir -p "$1"
  cat > "$1/docker" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "compose" ]; then
  { printf 'cwd=%s\n' "\$PWD"; printf 'argv=%s\n' "\$*"; } >> "$2"
  exit 0
fi
# restart / start / inspect: the container does not exist.
echo "Error response from daemon: No such container: \${2:-}" >&2
exit 1
STUB
  chmod +x "$1/docker"
  # bring_up sleeps 5s per attempt x8 + 5s after the recreate. Not in a test.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/sleep"
  chmod +x "$1/sleep"
}

# Extract mcp_up() + bring_up() verbatim from a restore-all copy and run them.
# Fail loudly if the functions are gone or renamed -- a tester that silently
# tests nothing is the thing this repo keeps getting burned by.
drive() { # $1 = restore-all path, $2 = compose dir, $3 = container to revive -> stdout: record file
  local sh_file="$1" compose_dir="$2" container="$3"
  local fn rec bin
  fn="$(awk '/^  mcp_up\(\) \{/{f=1} f{print} f&&/^  \}$/{exit}' "$sh_file" | sed 's/^  //')"
  case "$fn" in
    *"bring_up()"*) : ;;
    *) echo "::error::could not extract mcp_up()+bring_up() from $sh_file"; exit 1 ;;
  esac
  rec="$(mktemp "$WORK/record.XXXXXX")"
  bin="$(mktemp -d "$WORK/bin.XXXXXX")"
  mkstub "$bin" "$rec"
  (
    export PATH="$bin:$PATH"
    export CGC_COMPOSE_DIR="$compose_dir"
    eval "$fn"
    bring_up "$container" >/dev/null 2>&1
  )
  printf '%s' "$rec"
}

# A deployment shaped exactly like the real one: project dir holds compose/, and
# Ship's symlink .secrets -> compose/.secrets sits at the project root.
DEPLOY="$WORK/opt/containers/cloud-cgc-pub-mcp"
mkdir -p "$DEPLOY/compose"
printf 'services: {}\n' > "$DEPLOY/compose/docker-compose.yml"
printf 'TOKEN=stub\n'    > "$DEPLOY/compose/.secrets"
ln -sf compose/.secrets "$DEPLOY/.secrets"

echo "== 1_cicd/src/ops/cloud-cgc-db-restore-all.sh =="
SRC="$REPO_ROOT/1_cicd/src/ops/cloud-cgc-db-restore-all.sh"
[ -f "$SRC" ] || { echo "::error::not found: $SRC"; exit 1; }
REC="$(drive "$SRC" "$DEPLOY/compose" cloud-cgc-pub-mcp)"

if [ ! -s "$REC" ]; then
  bad "bring_up never reached the compose recreate (nothing recorded)"
else
  ok "bring_up falls through to the compose recreate when the container is gone"

  CWD="$(sed -n 's/^cwd=//p' "$REC" | head -1)"
  ARGV="$(sed -n 's/^argv=//p' "$REC" | head -1)"

  # THE bug: cwd was the compose/ subdir, so the project name became "compose".
  if [ "$CWD" = "$DEPLOY" ]; then
    ok "runs from the DEPLOY path (project = $(basename "$DEPLOY")), not the compose/ subdir"
  else
    bad "runs from '$CWD'; expected '$DEPLOY' — project name would be '$(basename "$CWD")'"
  fi

  case "$ARGV" in
    *"--project-directory ."*)
      ok "passes --project-directory . (pins project + env_file/volume resolution to Ship's)" ;;
    *)
      bad "no '--project-directory .' in: $ARGV" ;;
  esac

  case "$ARGV" in
    *"-f compose/docker-compose.yml"*)
      ok "names the compose file relative to the project dir" ;;
    *)
      bad "compose file not given as 'compose/docker-compose.yml': $ARGV" ;;
  esac

  # THE other half: listing both containers dragged the healthy sibling into the
  # transaction, and ITS name conflict killed the recreate of the one that was down.
  case "$ARGV" in
    *cloud-cgc-pvt-mcp*)
      bad "still names the sibling cloud-cgc-pvt-mcp — one container's conflict aborts the other's recreate: $ARGV" ;;
    *)
      ok "brings up ONLY the container that is down; the healthy sibling is untouched" ;;
  esac

  case "$ARGV" in
    *"up -d cloud-cgc-pub-mcp") ok "the service brought up is the one bring_up was asked to revive" ;;
    *) bad "does not end with 'up -d cloud-cgc-pub-mcp': $ARGV" ;;
  esac
fi

# The same code ships to the box as the generated dist copy — that is the one
# cgc-db-index.yml scp's over (`ssh_retry 1_cicd/dist/scripts/...`). A fix that
# lives only in src/ never reaches oci-apps.
echo "== 1_cicd/dist/scripts/cloud-cgc-db-restore-all.sh (the copy that ships) =="
DIST="$REPO_ROOT/1_cicd/dist/scripts/cloud-cgc-db-restore-all.sh"
if [ ! -f "$DIST" ]; then
  bad "dist copy missing: $DIST"
else
  REC2="$(drive "$DIST" "$DEPLOY/compose" cloud-cgc-pub-mcp)"
  ARGV2="$(sed -n 's/^argv=//p' "$REC2" | head -1)"
  CWD2="$(sed -n 's/^cwd=//p' "$REC2" | head -1)"
  if [ "$CWD2" = "$DEPLOY" ] && [ "$ARGV2" = "$(sed -n 's/^argv=//p' "$REC" | head -1)" ]; then
    ok "dist copy is regenerated and behaves identically to src"
  else
    bad "dist copy differs from src — run 'sh build.sh workflow' (cwd=$CWD2 argv=$ARGV2)"
  fi
fi

# The failure message tells a human how to recover by hand. It used to hand them
# the very command that cannot work.
echo "== the recovery instruction =="
RECOVER="$(grep -c 'Run it from the DEPLOY PATH with --project-directory' "$SRC" || true)"
if [ "${RECOVER:-0}" -ge 1 ]; then
  ok "the DOWN-after-swap error tells the operator to use the deploy path, not compose/"
else
  bad "the recovery instruction still points at the compose/ subdir form"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
