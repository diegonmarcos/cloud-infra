# Vault as Single Owner of All SOPS Secrets

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Draft
> **Note**: Engine pipeline changes (secrets-before-build, symlink check) moved to TASK-sec-01

---

## Checklist

- [ ] Phase 1: Create vault/E0_secrets/ structure + copy all secrets
- [ ] Phase 2: GHA vault access (deploy key + setup-deps clone step)
- [ ] Phase 3: Replace secrets files with symlinks in cloud/unix/front
- [ ] Phase 4: Documentation updates

---

> **Scope**: `vault/E0_secrets/`, `cloud/a_solutions/*/src/secrets.yaml`, `unix/b{a,b}_flakes_*/`, `front/secrets.yaml`, `cloud/.github/`

---

## Problem

All 3 public repos (cloud, unix, front) contain sops-encrypted `secrets.yaml` files. While encrypted, the ciphertext, age recipients, and key names are visible in public repos. The vault repo is private and already owns raw credentials.

**Goal**: Make vault the single owner of all sops-encrypted secrets, with public repos containing only symlinks.

**Engine changes**: The pipeline reorder (secrets before build) and symlink check in `step_secrets` are handled by TASK-sec-01 (engine v2). This task only covers the vault structure, GHA access, and symlink migration.

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

6. Generate read-only SSH deploy key for `diegonmarcos/cloud-vault`
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
      git clone --depth 1 git@github.com:diegonmarcos/cloud-vault.git "$GITHUB_WORKSPACE/../vault"
```

**GHA runner layout** (symlinks resolve correctly):
```
/home/runner/work/cloud/
  cloud/    <- $GITHUB_WORKSPACE
  vault/    <- cloned sibling (../../../../vault/ resolves here)
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
16. Verify: `sops -d` still works through symlinks
17. Test: `build.sh all` on one service locally
18. Commit + push all 3 repos (symlinks only, no encrypted content)

---

## Phase 4: History Cleanup (Optional)

19. Use `git filter-repo` to remove `*/secrets.yaml` and `*/jwks_key.yaml` from cloud git history
20. Force-push cloud (coordinate with forks)
21. Same for unix and front if desired

> Optional — files were always encrypted, but removes ciphertext from history for defense in depth.

---

## Phase 5: Documentation

22. Update `vault/README.md` — document E0_secrets structure
23. Update `cloud/README.md` — document symlink-to-vault pattern
24. Update CLAUDE.md source (in unix flakes) — document vault symlink pattern

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
| `cloud/a_solutions/*/src/secrets.yaml` (x32) | File -> symlink |
| `cloud/a_solutions/bb-sec_authelia/src/jwks_key.yaml` | File -> symlink |
| `cloud/b_infra/_shared/secrets.yaml` | File -> symlink |
| `cloud/.sops.yaml` | Removed (moved to vault) |
| `cloud/.github/actions/setup-deps/action.yml` | Add vault clone step |
| `cloud/.github/workflows/ship-*.yml` (x6) | Pass vault_deploy_key |
| `unix/b{a,b}_flakes_*/src/**/secrets.yaml` (x3) | File -> symlink |
| `front/secrets.yaml` | File -> symlink |
