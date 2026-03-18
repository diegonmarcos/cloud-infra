# GHA Pipeline Optimization

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Draft

---

## Checklist

- [ ] Phase 1: Pin sops binary (replace nix-shell)
- [ ] Phase 2: Cache nix store
- [ ] Phase 3: Single SSH session (deploy + compose)
- [ ] Phase 4: rsync compression + delta optimization
- [ ] Phase 5: Hash-before-deploy (skip rsync entirely if unchanged)
- [ ] Phase 6: WireGuard tunnel from GHA runner

---

## Current Baseline (authelia ship, config-only service)

| Step | Duration | % | What |
|------|----------|---|------|
| Runner boot + checkout | 5s | 2% | actions/checkout, paths-filter |
| Install Nix | 4s | 2% | cachix/install-nix-action |
| `build.sh deps` (nix-shell sops) | 29s | 13% | Evaluates nixpkgs to get sops binary |
| SSH setup + sops age key | 20s | 9% | Write SSH key, known_hosts, age key |
| `build.sh ship` — nix build | 9s | 4% | Evaluate flake → dist/ |
| secrets decrypt | 1s | <1% | sops -d → .secrets |
| rsync deploy | 108s | 49% | Transfer dist/ to VM |
| docker compose up | 40s | 18% | SSH → compose up + health verify |
| **Total** | **~220s** | **100%** | |

**Target**: < 60s for config-only services (no Docker build).

---

## Phase 1: Pin sops Binary (saves ~25s)

Replace `nix-shell -p sops` with direct binary download. sops is a single static binary.

### In `setup-deps/action.yml`:

```yaml
- name: Install sops
  shell: bash
  run: |
    SOPS_VERSION="3.9.4"
    curl -sSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
      -o /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
```

### In `_engine.sh` `build.sh deps`:

Remove `nix-shell -p sops` from the deps command. `sops` is already on PATH from the GHA step.

**Files**: `.github/actions/setup-deps/action.yml`, `_engine.sh` (deps command)

---

## Phase 2: Cache Nix Store (saves ~9s build, prevents future regression)

Add `nix-community/cache-nix-action` or GHA cache for `/nix/store`.

```yaml
- name: Cache nix store
  uses: nix-community/cache-nix-action@v6
  with:
    primary-key: nix-${{ runner.os }}-${{ hashFiles('**/flake.lock') }}
    restore-prefixes-first-match: nix-${{ runner.os }}-
```

For config-only services the nix build is already fast (9s), but this prevents regression as flakes grow. Also speeds up `source_code` services that have heavier builds.

**Files**: `.github/actions/setup-deps/action.yml`

---

## Phase 3: Single SSH Session (saves ~20-30s)

Current pipeline opens 4+ SSH connections (deploy rsync, compose up, health check, log fetch). Each has connection overhead (~5s handshake to slow VMs).

### Solution: SSH ControlMaster persistent socket

```yaml
- name: SSH setup
  shell: bash
  run: |
    mkdir -p ~/.ssh/sockets
    cat >> ~/.ssh/config <<EOF
    Host *
      ControlMaster auto
      ControlPath ~/.ssh/sockets/%r@%h-%p
      ControlPersist 300
    EOF
```

First SSH connection opens the socket, subsequent ones reuse it — near-zero overhead.

### In `_engine.sh`:

Add SSH_OPTS with ControlMaster:

```bash
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-%r@%h-%p -o ControlPersist=120"
```

**Check**: May already be partially implemented — verify current SSH_OPTS in engine.

**Files**: `.github/actions/setup-deps/action.yml`, `_engine.sh`

---

## Phase 4: rsync Compression + Delta (saves ~50-60s)

Current rsync is the biggest bottleneck (108s / 49%). The GHA runner → VM path goes over public internet.

### Optimizations:

```bash
# Current (likely)
rsync -avz dist/ vm:path/

# Optimized
rsync -az --compress-level=9 --partial --inplace dist/ vm:path/
```

| Flag | Effect |
|------|--------|
| `--compress-level=9` | Max compression (small config files compress well) |
| `--partial` | Resume interrupted transfers |
| `--inplace` | Update files in-place (no temp copy → less I/O) |
| `--checksum` | Compare by checksum not mtime (skip unchanged files reliably) |

### Also: strip docs from deploy

Many services generate `docs/` in dist/ (mdbook output). These are large and not needed on the VM.

```bash
# In step_deploy, add exclude
rsync ... --exclude='docs/' dist/ vm:path/
```

**Files**: `_engine.sh` (step_deploy rsync flags)

---

## Phase 5: Hash-Before-Deploy (saves full rsync on no-change)

The engine already hashes dist/ after build to skip deploy if unchanged. But the hash is stored locally in `.dist-hash` on the GHA runner — which is ephemeral. Each run rebuilds from scratch and always deploys.

### Solution: Store hash on the VM

```bash
# After successful deploy, write hash to VM
ssh $VM "echo '$NEW_HASH' > $DEPLOY_PATH/.dist-hash"

# Before deploy, read hash from VM
OLD_HASH=$(ssh $VM "cat $DEPLOY_PATH/.dist-hash 2>/dev/null" || true)

# Compare
if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    log "Config unchanged on VM — skipping deploy+compose"
    return 0
fi
```

This skips rsync + compose entirely when nothing changed. The most common case for multi-service workflows (push changes one service, all others skip).

**Files**: `_engine.sh` (step_deploy, ship flow)

---

## Phase 6: WireGuard Tunnel from GHA (saves ~50% rsync time)

Route GHA runner traffic through WireGuard to reach VMs via private IPs. This could dramatically improve rsync speed by going through the WG mesh.

### Setup:

1. Add `WG_PRIVATE_KEY` to GitHub Secrets
2. Allocate a WG IP for GHA runner (e.g., `10.0.0.20`)
3. Add peer to `mesh-topology.nix` for GHA
4. In GHA setup step:

```yaml
- name: WireGuard tunnel
  shell: bash
  run: |
    sudo apt-get install -y wireguard-tools
    sudo ip link add wg-gha type wireguard
    echo "${{ secrets.WG_PRIVATE_KEY }}" | sudo wg set wg-gha private-key /dev/stdin \
      peer $GCP_PROXY_PUBKEY endpoint 35.226.147.64:51820 \
      allowed-ips 10.0.0.0/24
    sudo ip addr add 10.0.0.20/24 dev wg-gha
    sudo ip link set wg-gha up
    sudo ip route add 10.0.0.0/24 dev wg-gha
```

5. rsync/SSH now uses WG IPs (10.0.0.x) instead of public IPs

### Caveats:

- Ephemeral runner = ephemeral WG peer (key regenerated each run OR static key in secrets)
- Static key approach: store WG private key in GitHub Secrets, GHA peer always has same pubkey
- Need to add GHA peer to all VMs' wireguard.nix AllowedIPs
- **Security**: The WG key in GitHub Secrets has access to the entire mesh. Scope with AllowedIPs.

**Effort**: Medium — depends on TASK-sec-03 (mesh-topology.nix) for clean peer management.
**Dependency**: Can be done standalone, but cleaner after sec-03.

**Files**: `.github/actions/setup-deps/action.yml`, `b_infra/home-manager/_shared/wireguard.nix` or `mesh-topology.nix`

---

## Projected Savings

| Phase | Saves | Cumulative | New Total |
|-------|-------|------------|-----------|
| Baseline | — | — | ~220s |
| Phase 1: Pin sops | ~25s | 25s | ~195s |
| Phase 2: Nix cache | ~5s (config-only) | 30s | ~190s |
| Phase 3: SSH ControlMaster | ~20s | 50s | ~170s |
| Phase 4: rsync optimize | ~40s | 90s | ~130s |
| Phase 5: Hash-on-VM (no-change) | ~150s (full skip) | — | **~15s** |
| Phase 6: WG tunnel | ~30s more on rsync | 120s | **~100s** |

**No-change deploy** (most common in multi-service workflows): **~15s** after Phase 5.
**Changed deploy**: **~60-100s** after all phases (down from 220s).

---

## Implementation Order

1. **Phase 1 + 3** together (easy, no dependencies) — pin sops + SSH ControlMaster
2. **Phase 4** (rsync flags, easy)
3. **Phase 5** (hash-on-VM, medium — engine change)
4. **Phase 2** (nix cache, easy but low impact for config-only)
5. **Phase 6** (WG tunnel, medium effort, best after sec-03)

---

## Files Modified

| File | Change |
|------|--------|
| `.github/actions/setup-deps/action.yml` | Pin sops binary, SSH ControlMaster, nix cache, WG tunnel |
| `a_solutions/_engine.sh` | rsync flags, hash-on-VM, SSH_OPTS ControlMaster |
| `b_infra/home-manager/_shared/wireguard.nix` | Add GHA peer (Phase 6) |
