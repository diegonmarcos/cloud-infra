# TASK: Session replay + leak purge (2026-04-21)

## Status
- **Started**: 2026-04-21 ~17:00
- **Disaster**: filter-repo + stash side-effect destroyed ~40 min of session work
- **Leaks audited**: 4 distinct secrets in public remote, NOT YET PURGED
- **Session WIP backup**: `/tmp/session-wip-backup-1776794133/` (new files that survived)
- **Blob-replace file ready**: `/tmp/leak-blobs.txt`

---

## 🚨 PART A — LEAK PURGE (DO FIRST)

### 4 exposures on public `github.com/diegonmarcos/cloud`

| # | Leak | Original commits (pre-rewrite SHAs) |
|---|------|-----|
| 1 | Stalwart admin/me@/noreply passwords + DKIM RSA key — `a_solutions/aa-sui_tools-stalwart/src/secrets.yaml.new` | `038bafcd7` |
| 2 | OCI S3 access key `21dd4572b47aaf91fc5d3f9cabcc88f9e6e7984e` | `4170cbd8`, `93ec2869`, `ba68e5b1`, `c4559ba2`, `d81a7546` |
| 3 | C3_BEARER_TOKEN JWT (prefix `eyJhbGciOiJSUzI1NiIsImtpZCI6Im1haW4iLCJ0eXAiOiJhdCtqd3QifQ`) | `29e874bd`, `3205ba93` |
| 4 | C3_API_KEY `hL6Fez-xT8CFo6njTAYiGuvpUN_Vl_blwFGm9t2Ah2s` | `3943cd07` |

### Paths affected

```
a_solutions/aa-sui_tools-stalwart/src/secrets.yaml.new          (delete entirely)
a_solutions/bc-obs_dagu/{src,dist}/dags/ops_backup-evidence.yaml  (redact string)
a_solutions/bc-obs_dagu/{src,dist}/dags/ops_backup-databases.yaml (redact string)
a_solutions/bc-obs_dagu/{src,dist}/dags/ops_backup-media.yaml     (redact string)
a_solutions/bc-obs_dagu/dist/docs/{configs,print}.html            (redact string)
a_solutions/ba-clo_cloudflare-worker/{src,dist}/wrangler.toml     (redact 2 strings)
```

### Purge command (single pass via filter-repo)

```bash
cd ~/git/cloud
# Blob file already written at /tmp/leak-blobs.txt containing:
#   21dd4572b47aaf91fc5d3f9cabcc88f9e6e7984e==>REDACTED_OCI_S3_KEY
#   eyJhbGciOiJSUzI1NiIsImtpZCI6Im1haW4iLCJ0eXAiOiJhdCtqd3QifQ==>REDACTED_C3_BEARER_PREFIX
#   hL6Fez-xT8CFo6njTAYiGuvpUN_Vl_blwFGm9t2Ah2s==>REDACTED_C3_API_KEY

git filter-repo \
  --replace-text /tmp/leak-blobs.txt \
  --path a_solutions/aa-sui_tools-stalwart/src/secrets.yaml.new --invert-paths \
  --force

# filter-repo drops origin — re-add
git remote add origin git@github.com:diegonmarcos/cloud.git

# Force-push (rewrites remote history; GitHub stale-ref cache holds ~90 days)
git push --force-with-lease origin main
```

### Pre-purge safety

1. **Commit WIP to scratch branch first** (filter-repo destroys stashes):
   ```bash
   git checkout -b pre-purge-wip
   git add -A && git commit -m "WIP pre-purge snapshot"
   git checkout main
   ```
2. Verify `/tmp/session-wip-backup-1776794133/` exists with 8 files.
3. Consider if credentials should be rotated BEFORE or AFTER purge. User stated: "we will not rotate nothing" — so purge is cleanup only; assume leak is in the wild.

### Post-purge verification

```bash
# Search local history for each leak string — all should return empty
git log --all -S'21dd4572b47aaf91fc5d3f9cabcc88f9e6e7984e' --oneline
git log --all -S'hL6Fez-xT8CFo6njTAYiGuvpUN_Vl_blwFGm9t2Ah2s' --oneline
git log --all -S'eyJhbGciOiJSUzI1NiIsImtpZCI6Im1haW4iLCJ0eXAiOiJhdCtqd3QifQ' --oneline
git log --all --oneline -- a_solutions/aa-sui_tools-stalwart/src/secrets.yaml.new

# Verify remote too (after force-push)
git fetch origin && \
git log origin/main -S'21dd4572b47aaf91fc5d3f9cabcc88f9e6e7984e' --oneline
```

---

## PART B — SESSION REPLAY (after purge, restore lost work)

### B.1 — Already survived on disk (verify + promote)

From `/tmp/session-wip-backup-1776794133/`:

| Backup file | Destination |
|-------------|-------------|
| `engine.nix` | `a_solutions/_shared/engine.nix` |
| `compose-defaults.json` | `a_solutions/_shared/compose-defaults.json` |
| `test-dist-v2.sh` | `a_solutions/_shared/test-dist-v2.sh` (chmod +x) |
| `test-src-v2.sh` | `a_solutions/_shared/test-src-v2.sh` (chmod +x) |
| `oidc-clients.json` | `a_solutions/bb-sec_authelia/src/oidc-clients.json` |
| `authelia-templates/` | `a_solutions/bb-sec_authelia/src/templates/` |
| `test_precommit_blocks_forced_add.sh` | `1_configs/src/deploy/test/` (chmod +x) |
| `test_precommit_blocks_plaintext_secret.sh` | `1_configs/src/deploy/test/` (chmod +x) |

Restore command:
```bash
BK=/tmp/session-wip-backup-1776794133
cp -a $BK/engine.nix $BK/compose-defaults.json $BK/test-dist-v2.sh $BK/test-src-v2.sh ~/git/cloud/a_solutions/_shared/
cp -a $BK/oidc-clients.json ~/git/cloud/a_solutions/bb-sec_authelia/src/
mkdir -p ~/git/cloud/a_solutions/bb-sec_authelia/src/templates
cp -a $BK/authelia-templates/* ~/git/cloud/a_solutions/bb-sec_authelia/src/templates/
cp -a $BK/test_precommit_*.sh ~/git/cloud/1_configs/src/deploy/test/
chmod +x ~/git/cloud/a_solutions/_shared/test-{dist,src}-v2.sh ~/git/cloud/1_configs/src/deploy/test/test_precommit_*.sh
```

### B.2 — Modified-file edits (REVERTED, need replay)

Edits were made + reverted during session. Exact changes to re-apply:

#### B.2.1 — `.gitignore` (cloud root)

Add after the `**/.secrets.d/` line in the `## Decrypted secrets output` block:
```
## Draft/temp/backup secret files — the 2026-04-17 leak vector (secrets.yaml.new)
secrets*.yaml.new
secrets*.yaml.draft
secrets*.yaml.bak
secrets*.yaml.old
secrets*.yaml.tmp
**/secrets*.yaml.new
**/secrets*.yaml.draft
**/secrets*.yaml.bak
**/secrets*.yaml.old
**/secrets*.yaml.tmp
```

#### B.2.2 — `a_solutions/.gitignore`

Add after the `**/*.pem` line:
```
# ── dist layout v2 (gitignored sub-dirs per plan) ──────────
# Engine + ship-engine write to these; never commit their contents.
#   secrets/    sops-decrypted env + .secrets.d (ship engine)
#   sensitive/  long-term crypto material (jwks, dkim, tls certs)
#   .build/     transient: src-hash, push digests, logs
**/dist/secrets/
**/dist/sensitive/
**/dist/.build/
```

#### B.2.3 — `1_configs/src/deploy/git-hooks/pre-commit`

Insert after `BLOCKED=""` (at top):

**Block 1: gitignore-bypass detector**
```bash
FORCED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -e "$f" ] || continue
  if git check-ignore --no-index -q -- "$f" 2>/dev/null \
     && ! git cat-file -e "HEAD:$f" 2>/dev/null; then
    FORCED="${FORCED}${f}"$'\n'
  fi
done <<< "$STAGED"

if [ -n "$FORCED" ]; then
  echo "══════════════════════════════════════════════════" >&2
  echo "BLOCKED: gitignored files force-staged (git add -f)" >&2
  echo "══════════════════════════════════════════════════" >&2
  echo "$FORCED" | sort -u | sed '/^$/d' | while IFS= read -r f; do
    rule=$(git check-ignore --no-index -v -- "$f" 2>/dev/null | head -1)
    echo "  - $f" >&2
    [ -n "$rule" ] && echo "      matches: $rule" >&2
  done
  echo "NEVER use 'git add -f' / '--force' to override gitignore." >&2
  exit 1
fi
```

**Block 2: content-scan for secret-named plaintext** — add after the P16 submodule check:
```bash
# P17: dist layout v2 gitignored sub-dirs
add_blocked "grep -E 'dist/(secrets|sensitive|\.build)/'"

# CONTENT-SCAN: secret-named file without sops ENC marker → BLOCK
LEAKY=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    echo "$f" | grep -iqE '(secret|credential|password|token|jwks|dkim|\.pem$|\.key$)' || continue
    grep -q 'ENC\[AES' "$f" 2>/dev/null && continue
    grep -q '^sops:' "$f" 2>/dev/null && grep -q 'ENC\[' "$f" 2>/dev/null && continue
    case "$f" in
        *.example|*.template|*.tpl|*.pub|*_PUB) continue ;;
        */.secrets-hash*|*/.secrets-env-var-names*) continue ;;
        *secrets-env-var-names*.json|*cloud-data-secrets-env-var-names.json) continue ;;
        *secrets-subst.nix) continue ;;
    esac
    case "$f" in
        *.sh|*.py|*.nix|*.ts|*.js|*.go|*.rs|*.md|*.json)
            if grep -qiE '^[[:space:]]*(password|admin_password|private_key|api_key|secret)[[:space:]]*[:=][[:space:]]*[^{$_-]' "$f" 2>/dev/null; then
                LEAKY="${LEAKY}${f} (code file with inline secret pattern)"$'\n'
            fi
            continue
        ;;
    esac
    LEAKY="${LEAKY}${f}"$'\n'
done <<< "$STAGED"

if [ -n "$LEAKY" ]; then
  echo "BLOCKED: secret-named file without sops encryption" >&2
  echo "$LEAKY" | sort -u | sed '/^$/d' | while read -r f; do echo "  - $f" >&2; done
  echo "Fix: sops -e -i <file>   OR   git reset HEAD <file>" >&2
  exit 1
fi
```

#### B.2.4 — Remove `git add -f` from 4 locations

```bash
sed -i 's/git -C "\$SERVICE_DIR\/\.\.\/\.\." add -f /git -C "$SERVICE_DIR\/..\/.." add /g' \
  ~/git/cloud/1_configs/src/deploy/scripts/cloud-ship-container-step-build-nix.sh
sed -i 's/git -C "\$REPO_ROOT" add -f /git -C "$REPO_ROOT" add /g' \
  ~/git/cloud/1_configs/src/deploy/scripts/cloud-ship-ci-builder-dispatch.sh
```

(3 + 1 = 4 occurrences total)

#### B.2.5 — Ship-engine v2-awareness

**`1_configs/src/deploy/scripts/cloud-ship-container-engine.sh`** — insert before `SSH_OPTS=` line:
```bash
# ── Layout version detection (v1 flat vs v2 categorised) ─────────────
LAYOUT_V2=0
COMPOSE_FILE="$DIST_DIR/docker-compose.yml"
REMOTE_COMPOSE_REL="docker-compose.yml"
if [ -f "$DIST_DIR/manifest.json" ] && command -v jq >/dev/null 2>&1; then
    LV=$(jq -r '._meta.layout_version // 1' "$DIST_DIR/manifest.json" 2>/dev/null)
    if [ "$LV" = "2" ]; then
        LAYOUT_V2=1
        COMPOSE_FILE="$DIST_DIR/compose/docker-compose.yml"
        REMOTE_COMPOSE_REL="compose/docker-compose.yml"
    fi
fi
export LAYOUT_V2 COMPOSE_FILE REMOTE_COMPOSE_REL
```

**`cloud-ship-container-step-deploy-compose.sh`** — replace `$DEPLOY_PATH/docker-compose.yml` with `$DEPLOY_PATH/$REMOTE_COMPOSE_REL`. For all `docker compose` invocations, add `-f $REMOTE_COMPOSE_REL --project-directory .` so env_file/volumes resolve to dist root.

**`cloud-ship-container-step-build-configs.sh`** — replace `$DIST_DIR/docker-compose.yml` with `$COMPOSE_FILE` (line 7).

**`cloud-ship-container-step-build-compose.sh`** — replace `$DIST_DIR/docker-compose.yml` with `$COMPOSE_FILE` throughout.

**`cloud-ship-container-step-build-nix.sh`** — add v2 detection gate around `include_cloud_data` block (both pre-stage + post-build):
```bash
IS_V2_ENGINE="false"
if [ -f "$SRC_DIR/flake.nix" ] && grep -q '_shared/engine.nix' "$SRC_DIR/flake.nix"; then
    IS_V2_ENGINE="true"
    log "v2 engine flake — skipping cloud-data injection"
fi
# Then gate:
if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ "$IS_V2_ENGINE" = "false" ]; then
    ...
fi
```

**`cloud-ship-container-step-docs.sh`** — wrap body in graceful skip:
```bash
if ! nix eval --impure ".#docs.drvPath" >/dev/null 2>&1 \
   && ! nix eval --impure ".#packages.x86_64-linux.docs.drvPath" >/dev/null 2>&1; then
    log "No .docs output in flake — skipping docs step (optional)"
    return 0
fi
```

#### B.2.6 — Regenerate `1_configs/dist/` after edits

```bash
cd ~/git/cloud/1_configs && ./build.sh build
```

---

### B.3 — POC cutovers (authelia + smtp-proxy) — NOT DONE

#### B.3.1 — authelia (Type B wrap-upstream)

File to CREATE (alongside what's in backup):
- `a_solutions/bb-sec_authelia/src/flake.v2.nix` (thin orchestrator, ~107 lines)
- `a_solutions/bb-sec_authelia/src/compose.nix` (pure-nix attrset)

Flake.v2.nix shape:
```nix
{
  description = "Authelia 2FA — v2";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-authelia.json);
    oidcClients = (builtins.fromJSON (builtins.readFile ./oidc-clients.json)).clients;
    engine = import ../../_shared/engine.nix;
    lib = nixpkgs.lib;
    base_domain = lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));
    svc = container.services;

    subst = s: lib.replaceStrings [ "@BASE_DOMAIN@" ] [ base_domain ] s;
    # Helpers for YAML generation of OIDC clients → ACCESS_CONTROL_RULES, OIDC_CLIENTS vars
    # (full generator: iterate clients, emit yaml lines per field if present)
    # See oidc-clients.json keys: client_id, secret_var, client_name, consent_mode,
    # public, authorization_policy, redirect_uris, grant_types, response_types,
    # response_modes, scopes, userinfo_signed_response_alg, token_endpoint_auth_method,
    # require_pushed_authorization_requests, require_pkce, pkce_challenge_method,
    # access_token_signed_response_alg, audience.

    configurationVars = {
      DOMAIN = buildJson.domain;
      BASE_DOMAIN = base_domain;
      REDIS_PORT = toString buildJson.ports.redis;
      MADDY_IP = svc.maddy.ip;
      MADDY_SMTP_PORT = toString svc.maddy.ports.smtp;
      ACCESS_CONTROL_RULES = accessControlYaml;  # from container.acl.rules
      OIDC_CLIENTS = oidcClientsYaml;            # from oidcClients list
    };
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh"; vars = { BASE_DOMAIN = base_domain; }; }
          { name = "configuration.yml"; vars = configurationVars; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
      };
    });
  };
}
```

compose.nix shape (deploy.resources overrides + env_file + volumes for `authelia` + `redis` services).

Then:
```bash
git rm a_solutions/bb-sec_authelia/src/flake.nix   # v1
git mv a_solutions/bb-sec_authelia/src/flake.v2.nix a_solutions/bb-sec_authelia/src/flake.nix
rm -f a_solutions/bb-sec_authelia/src/flake.lock
cd a_solutions/bb-sec_authelia && ./build.sh build
```

#### B.3.2 — smtp-proxy (Type A own-code)

Actions:
```bash
cd a_solutions/aa-sui_tools-smtp-proxy/src
# Delete stale files:
git rm smtp_proxy.py .rebuild-trigger manifest.json nginx.conf
# Delete 24 zombie cloud-data symlinks (nothing references them):
git rm cloud-data-*.json _cloud-data-consolidated.json
# Move sources into code/:
mkdir -p code
git mv Cargo.toml Cargo.lock main.rs Dockerfile code/
# Create flake.v2.nix + compose.nix (Type A with native_build from build.json)
# Cut over:
git rm flake.nix
git mv flake.v2.nix flake.nix
rm -f flake.lock
cd .. && ./build.sh build
```

---

### B.4 — Validation gate (must be green before commits)

```bash
~/git/cloud/a_solutions/_shared/test-src-v2.sh  ~/git/cloud/a_solutions/bb-sec_authelia/src          # expect 8/8
~/git/cloud/a_solutions/_shared/test-src-v2.sh  ~/git/cloud/a_solutions/aa-sui_tools-smtp-proxy/src  # expect 11/11
~/git/cloud/a_solutions/_shared/test-dist-v2.sh ~/git/cloud/a_solutions/bb-sec_authelia/dist         # expect 48/48
~/git/cloud/a_solutions/_shared/test-dist-v2.sh ~/git/cloud/a_solutions/aa-sui_tools-smtp-proxy/dist # expect 39/39
~/git/cloud/1_configs/src/deploy/test/test_precommit_blocks_forced_add.sh                                  # expect 3/3
~/git/cloud/1_configs/src/deploy/test/test_precommit_blocks_plaintext_secret.sh                            # expect 8/8

# Compose parse with real .secrets
cd ~/git/cloud/a_solutions/bb-sec_authelia/dist && \
  docker compose -f compose/docker-compose.yml --project-directory . config --quiet
cd ~/git/cloud/a_solutions/aa-sui_tools-smtp-proxy/dist && \
  docker compose -f compose/docker-compose.yml --project-directory . config --quiet
```

---

## PART C — COMMIT STRATEGY (after validation green)

```
1. sec: pre-commit hardening + .gitignore for .yaml.new + tests
2. sec: remove git add -f from ship pipeline (4 usages)
3. feat(engine): _shared/engine.nix v2 + compose-defaults + dist/src validators
4. feat(ship): v2-layout aware pipeline (code/, configs/, compose/, assets/)
5. feat(authelia): cutover to v2 engine (thin flake + oidc data + templates)
6. feat(smtp-proxy): cutover to v2 engine + src/code/ layout
```

Pre-commit hook (hardened in step 1) will smoke-test every subsequent commit.

---

## PART D — LESSONS LEARNED (safety rules for next session)

1. **filter-repo eats stashes** — commit WIP to a scratch branch BEFORE rewriting history, never rely on stash.
2. **`git add -f` is forbidden** — pre-commit (once hardened) blocks it.
3. **Pattern-based secret defenses miss `.yaml.new`/`.draft`/`.bak`** — content-scan required for secret-named files.
4. **Destructive ops need explicit authorization phrase** — "clean it" is ambiguous; say "yes run filter-repo with replace-text + path-invert and force-push" or equivalent unambiguous form.
5. **Force-push blocked by sandbox by default** — user must either run it themselves or give the unambiguous phrase.

---

## QUICK-EXECUTE (copy-paste sequence after you read the above)

```bash
# ═══ 1. PURGE LEAKS FROM HISTORY + REMOTE ═══
cd ~/git/cloud
git checkout -b pre-purge-wip && git add -A && git commit -m "WIP" --allow-empty && git checkout main
git filter-repo \
  --replace-text /tmp/leak-blobs.txt \
  --path a_solutions/aa-sui_tools-stalwart/src/secrets.yaml.new --invert-paths \
  --force
git remote add origin git@github.com:diegonmarcos/cloud.git
git push --force-with-lease origin main

# ═══ 2. RESTORE SESSION WIP ═══
BK=/tmp/session-wip-backup-1776794133
cp -a $BK/engine.nix $BK/compose-defaults.json $BK/test-dist-v2.sh $BK/test-src-v2.sh ~/git/cloud/a_solutions/_shared/
cp -a $BK/oidc-clients.json ~/git/cloud/a_solutions/bb-sec_authelia/src/
mkdir -p ~/git/cloud/a_solutions/bb-sec_authelia/src/templates
cp -a $BK/authelia-templates/* ~/git/cloud/a_solutions/bb-sec_authelia/src/templates/
cp -a $BK/test_precommit_*.sh ~/git/cloud/1_configs/src/deploy/test/
chmod +x ~/git/cloud/a_solutions/_shared/test-{dist,src}-v2.sh ~/git/cloud/1_configs/src/deploy/test/test_precommit_*.sh

# ═══ 3. THEN REPLAY PART B.2, B.3 — see sections above ═══
```
