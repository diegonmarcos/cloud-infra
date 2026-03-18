# Vault as Single Owner of All SOPS Secrets

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Draft

---

## Checklist

- [ ] Phase 1: Create vault/E0_secrets/ structure + copy all secrets
- [ ] Phase 2: GHA vault access (deploy key + setup-deps clone step)
- [ ] Phase 3: Replace secrets files with symlinks in cloud/unix/front
- [ ] Phase 4: Engine pipeline reorder (secrets before build)
- [ ] Phase 5: (Optional) git filter-repo history cleanup
- [ ] Phase 6: Documentation updates

---

> **Scope**: `vault/E0_secrets/`, `cloud/a_solutions/_engine.sh`, `cloud/.github/`, `cloud/a_solutions/*/src/secrets.yaml`, `unix/b{a,b}_flakes_*/`, `front/secrets.yaml`

---

## Problem

All 3 public repos (cloud, unix, front) contain sops-encrypted `secrets.yaml` files. While encrypted, the ciphertext, age recipients, and key names are visible in public repos. The vault repo is private and already owns raw credentials.

**Goal**: Make vault the single owner of all sops-encrypted secrets, with public repos containing only symlinks. Additionally, reorder the `_engine.sh` pipeline so secrets are decrypted first — making local and remote builds universal.

---

## Phase 1: Vault Structure

Create `vault/E0_secrets/` mirroring source repo paths:

```
vault/E0_secrets/
├── .sops.yaml                    # age recipient config (moved from cloud/)
├── cloud/
│   ├── a_solutions/
│   │   ├── aa-sui_affine/secrets.yaml
│   │   ├── aa-sui_code-server/secrets.yaml
│   │   ├── ...all ~32 services...
│   │   └── bb-sec_authelia/jwks_key.yaml
│   └── b_infra/
│       └── home-manager/secrets.yaml
├── unix/
│   ├── ba_flakes_desktop/
│   │   ├── secrets.yaml
│   │   └── claude-secrets.yaml
│   └── bb_flakes_termux/
│       └── claude-secrets.yaml
└── front/
    └── secrets.yaml
```

**Why `E0_`**: Follows vault's alphabetical convention (A0_keys, B0_Passwords, C0_ID, D0_bitwarden → E0_secrets).

### Steps

1. Create directory tree in vault
2. Copy all `secrets.yaml` files from cloud/unix/front → `vault/E0_secrets/`
3. Create `.sops.yaml` at `vault/E0_secrets/` with the age recipient
4. Verify all copied files decrypt: `sops -d` from vault paths
5. Commit + push vault

---

## Phase 2: GHA Vault Access

GHA needs to clone the private vault repo to resolve symlinks during `build.sh ship`.

### Steps

6. Generate read-only SSH deploy key for `diegonmarcos/vault`
7. Add `VAULT_DEPLOY_KEY` to cloud repo GitHub Secrets
8. Update `.github/actions/setup-deps/action.yml` — add vault clone step:

```yaml
inputs:
  vault_deploy_key:
    description: 'SSH deploy key for vault repo'
    required: false

- name: Clone vault
  if: inputs.vault_deploy_key
  shell: bash
  run: |
    echo "${{ inputs.vault_deploy_key }}" > ~/.ssh/vault_deploy
    chmod 600 ~/.ssh/vault_deploy
    GIT_SSH_COMMAND="ssh -i ~/.ssh/vault_deploy -o StrictHostKeyChecking=no" \
      git clone --depth 1 git@github.com:diegonmarcos/vault.git "$GITHUB_WORKSPACE/../vault"
```

**GHA runner layout** (symlinks resolve correctly):
```
/home/runner/work/cloud/
  cloud/    ← $GITHUB_WORKSPACE
  vault/    ← cloned sibling (../../../../vault/ resolves here)
```

9. Update all ship workflows to pass `vault_deploy_key: ${{ secrets.VAULT_DEPLOY_KEY }}`
10. Test with manual `workflow_dispatch` on one service

---

## Phase 3: Symlink Migration

Replace real files with relative symlinks to vault.

### Steps

11. Migration script (one-shot) for cloud:
```bash
for f in $(find a_solutions/*/src -name secrets.yaml -not -path '*/z_archive/*'); do
  service=$(echo "$f" | awk -F/ '{print $2}')
  vault_path="../../../../vault/E0_secrets/cloud/a_solutions/$service/secrets.yaml"
  rm "$f"
  ln -s "$vault_path" "$f"
done
```
12. Same for `jwks_key.yaml`, home-manager `_shared/secrets.yaml`
13. Same for unix secrets (claude secrets, desktop secrets)
14. Same for front secrets
15. Remove `.sops.yaml` from cloud root (now lives in vault)
16. Verify: `sops -d` still works through symlinks (finds `.sops.yaml` walking up into vault)
17. Test: `build.sh all` on one service locally
18. Commit + push all 3 repos (symlinks only, no encrypted content)

---

## Phase 4: Engine Pipeline Reorder

**Current ship order**:
```
docker → build → secrets → deploy → compose
```

**New ship order**:
```
secrets → build → [docker local] → deploy → [docker remote] → compose → health → report
```

### Steps

19. Move `step_secrets` before `step_build` in ship flow
20. Modify `step_build` to preserve `.secrets*` across `rm -rf "$DIST_DIR"`:
```bash
# Save secrets if they exist (from step_secrets running first)
if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/.secrets" ]; then
  _saved=$(mktemp -d)
  cp -a "$DIST_DIR/.secrets" "$DIST_DIR/.secrets.d" "$_saved/" 2>/dev/null || true
fi
rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"
# Restore
if [ -n "${_saved:-}" ] && [ -d "$_saved" ]; then
  cp -a "$_saved/"* "$DIST_DIR/" 2>/dev/null || true
  rm -rf "$_saved"
fi
```
21. Add symlink check in `step_secrets`:
```bash
if [ -L "$SRC_DIR/secrets.yaml" ] && [ ! -e "$SRC_DIR/secrets.yaml" ]; then
  log_warn "secrets.yaml symlink target missing (vault not cloned?) — skipping"
  return 0
fi
```
22. Result: `dist/` has BOTH config files (from flake) AND decrypted secrets before deploy — universal for local and remote builds

### Critical files

- `~/git/cloud/a_solutions/_engine.sh`
- `~/git/cloud/.github/actions/setup-deps/action.yml`
- `~/git/cloud/.github/workflows/ship-*.yml` (×6)

---

## Phase 5: History Cleanup (Optional)

23. Use `git filter-repo` to remove `*/secrets.yaml` and `*/jwks_key.yaml` from cloud git history
24. Force-push cloud (coordinate with forks)
25. Same for unix and front if desired

> Optional — files were always encrypted, but removes ciphertext from history for defense in depth.

---

## Phase 6: Documentation

26. Update `vault/README.md` — document E0_secrets structure
27. Update `cloud/README.md` — document symlink-to-vault pattern
28. Update CLAUDE.md source (in unix flakes) — document vault symlink pattern

---

## Verification

1. **Local**: `build.sh all` on `bb-sec_authelia` — secrets decrypt through symlink
2. **GHA**: Manual `workflow_dispatch` for one service — vault cloned, symlinks resolve, ship succeeds
3. **Security**: `git grep -r 'ENC\[AES' HEAD` in cloud repo returns 0 matches
4. **Vault**: `sops -d vault/E0_secrets/cloud/a_solutions/bb-sec_authelia/secrets.yaml` works
5. **No regression**: All services deploy, containers start healthy

---

## Files Modified

| File | Change |
|------|--------|
| `vault/E0_secrets/**` | NEW — all secrets.yaml files |
| `vault/E0_secrets/.sops.yaml` | NEW — sops config |
| `cloud/a_solutions/*/src/secrets.yaml` (×32) | File → symlink |
| `cloud/a_solutions/bb-sec_authelia/src/jwks_key.yaml` | File → symlink |
| `cloud/b_infra/home-manager/_shared/secrets.yaml` | File → symlink |
| `cloud/.sops.yaml` | Removed (moved to vault) |
| `cloud/a_solutions/_engine.sh` | Reorder ship, symlink check, preserve secrets in step_build |
| `cloud/.github/actions/setup-deps/action.yml` | Add vault clone step |
| `cloud/.github/workflows/ship-*.yml` (×6) | Pass vault_deploy_key |
| `unix/b{a,b}_flakes_*/src/**/secrets.yaml` (×3) | File → symlink |
| `front/secrets.yaml` | File → symlink |
