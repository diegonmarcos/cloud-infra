# GHA Pipeline Optimization — Fully Declarative

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: Draft

---

## Checklist

- [ ] Phase 1: Nix store cache (absorbs sops + build deps)
- [ ] Phase 2: GHA deps flake (sops, wireguard-tools, yq — single `nix develop`)
- [ ] Phase 3: SSH ControlMaster (single socket, reuse across steps)
- [ ] Phase 4: rsync compression + delta optimization
- [ ] Phase 5: Hash-before-deploy (skip rsync if unchanged)
- [ ] Phase 6: WireGuard tunnel via nix flake

---

## Current Baseline (authelia ship, config-only service)

| Step | Duration | % | What |
|------|----------|---|------|
| Runner boot + checkout | 5s | 2% | actions/checkout, paths-filter |
| Install Nix | 4s | 2% | cachix/install-nix-action |
| `build.sh deps` (nix-shell sops) | 29s | 13% | Evaluates nixpkgs to get sops binary |
| SSH setup + sops age key | 20s | 9% | Write SSH key, known_hosts, age key |
| `build.sh ship` — nix build | 9s | 4% | Evaluate flake -> dist/ |
| secrets decrypt | 1s | <1% | sops -d -> .secrets |
| rsync deploy | 108s | 49% | Transfer dist/ to VM |
| docker compose up | 40s | 18% | SSH -> compose up + health verify |
| **Total** | **~220s** | **100%** | |

**Target**: < 60s for config-only services (no Docker build).

---

## Phase 1: Cache Nix Store (saves ~30s — absorbs sops + all deps)

Cache `/nix/store` across GHA runs. First run populates the cache, subsequent runs restore in <2s. This makes `nix-shell -p sops` and `nix build` near-instant from cache.

**No need to pin sops binary** — nix-shell resolves from cached store.

### In `setup-deps/action.yml`:

```yaml
- name: Cache nix store
  uses: nix-community/cache-nix-action@v6
  with:
    primary-key: nix-${{ runner.os }}-${{ hashFiles('**/flake.lock') }}
    restore-prefixes-first-match: nix-${{ runner.os }}-
    paths: |
      /nix/store
      /nix/var/nix
      ~/.cache/nix
```

**Files**: `.github/actions/setup-deps/action.yml`

---

## Phase 2: GHA Deps Flake (declarative toolchain)

Replace ad-hoc `nix-shell -p sops` calls with a single flake that declares ALL GHA build dependencies. One `nix develop` enters the environment with everything available.

### New flake: `.github/flake.nix`

```nix
{
  description = "GHA CI/CD build environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        buildInputs = [
          pkgs.sops
          pkgs.age
          pkgs.yq-go
          pkgs.wireguard-tools  # for Phase 6
          pkgs.rsync
          pkgs.openssh
        ];
      };
    });
  };
}
```

### In `_engine.sh` `build.sh deps`:

```bash
cmd_deps() {
    # GHA: use .github/flake.nix devShell
    if [ -f "$REPO_ROOT/.github/flake.nix" ]; then
        log "Nix (develop): entering GHA build environment"
        nix develop "$REPO_ROOT/.github#" --command true  # populates nix store
        export PATH="$(nix develop "$REPO_ROOT/.github#" --print-dev-env 2>/dev/null | grep '^export PATH=' | cut -d= -f2- | tr -d '"'):$PATH"
    else
        # Fallback: individual nix-shell calls (local dev)
        for dep in sops age yq-go; do
            command -v "$dep" >/dev/null 2>&1 || nix_add "$dep"
        done
    fi
}
```

Or simpler — GHA action.yml does:

```yaml
- name: Enter build environment
  shell: bash
  run: |
    nix develop .github/#default --profile /tmp/gha-env
    echo "/tmp/gha-env/bin" >> "$GITHUB_PATH"
```

All tools on PATH, all from nix, all cached by Phase 1.

**Files**: `.github/flake.nix` (NEW), `.github/actions/setup-deps/action.yml`, `_engine.sh`

---

## Phase 3: SSH ControlMaster (saves ~20-30s)

Current pipeline opens 4+ SSH connections (deploy rsync, compose up, health check, log fetch). Each has ~5s handshake overhead.

### In `setup-deps/action.yml`:

```yaml
- name: SSH ControlMaster
  shell: bash
  run: |
    mkdir -p ~/.ssh/sockets
    cat >> ~/.ssh/config <<'EOF'
    Host *
      ControlMaster auto
      ControlPath ~/.ssh/sockets/%r@%h-%p
      ControlPersist 300
    EOF
```

First SSH connection opens the socket, all subsequent reuse it — near-zero overhead.

### In `_engine.sh`:

Verify `SSH_OPTS` includes ControlMaster (may already be there from SSH config above — no engine change needed if SSH config is global).

**Files**: `.github/actions/setup-deps/action.yml`

---

## Phase 4: rsync Compression + Delta (saves ~40-50s)

The biggest bottleneck (108s / 49%). GHA runner -> VM goes over public internet.

### In `_engine.sh` step_deploy:

```bash
# Optimized rsync flags
rsync -az \
    --compress-level=9 \
    --partial \
    --inplace \
    --checksum \
    --exclude='docs/' \
    -e "ssh $SSH_OPTS" \
    "$DIST_DIR/" "$DEPLOY_HOST:$DEPLOY_PATH/"
```

| Flag | Effect |
|------|--------|
| `--compress-level=9` | Max compression (config files compress >90%) |
| `--partial` | Resume interrupted transfers |
| `--inplace` | Update in-place (less I/O on VM) |
| `--checksum` | Skip unchanged files by content hash (not mtime) |
| `--exclude='docs/'` | Skip mdbook docs (large, not needed on VM) |

**Files**: `_engine.sh` (step_deploy)

---

## Phase 5: Hash-Before-Deploy (saves full rsync on no-change)

The engine hashes dist/ to skip deploy, but the hash lives on the ephemeral GHA runner (`.dist-hash`). Every run always deploys.

### Solution: Store hash on the VM (engine-managed deploy state)

```bash
# In step_deploy (before rsync):
# Read hash from VM
OLD_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat $DEPLOY_PATH/.dist-hash 2>/dev/null" || true)

# Compare with local dist/ hash
NEW_HASH=$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)

if [ "$OLD_HASH" = "$NEW_HASH" ] && [ -n "$NEW_HASH" ]; then
    log "Config unchanged on VM — skipping deploy+compose"
    return 0
fi

# ... rsync ...

# After successful deploy, write hash to VM
ssh $SSH_OPTS "$DEPLOY_HOST" "echo '$NEW_HASH' > $DEPLOY_PATH/.dist-hash"
```

This is engine-managed state (written by the deploy pipeline, read by the deploy pipeline). The `.dist-hash` file is part of the deployment artifact lifecycle — not an imperative hack.

**No-change skip**: checkout + nix build + hash check = ~15s total. Skips rsync + compose entirely.

**Files**: `_engine.sh` (ship flow, step_deploy)

---

## Phase 6: WireGuard Tunnel via Nix Flake (saves ~50% rsync)

Route GHA runner traffic through WireGuard mesh. All tools from the Phase 2 deps flake (`wireguard-tools` already declared there).

### Nix-based WG setup in `setup-deps/action.yml`:

```yaml
- name: WireGuard tunnel
  if: env.WG_PRIVATE_KEY != ''
  shell: bash
  run: |
    # wireguard-tools available from Phase 2 deps flake
    WG_CONFIG=$(nix eval --raw .github/#lib.ghaWireguardConfig)

    sudo ip link add wg-gha type wireguard
    echo "$WG_CONFIG" | sudo wg setconf wg-gha /dev/stdin
    sudo ip addr add 10.0.0.20/24 dev wg-gha
    sudo ip link set wg-gha up
    sudo ip route add 10.0.0.0/24 dev wg-gha
  env:
    WG_PRIVATE_KEY: ${{ secrets.GHA_WG_PRIVATE_KEY }}
```

### WG config generated from flake:

```nix
# In .github/flake.nix — add lib output
lib.ghaWireguardConfig = pkgs.writeText "wg-gha.conf" ''
  [Interface]
  PrivateKey = PLACEHOLDER_INJECTED_AT_RUNTIME

  [Peer]
  PublicKey = ${gcpProxyPubkey}
  Endpoint = 35.226.147.64:51820
  AllowedIPs = 10.0.0.0/24
  PersistentKeepalive = 25
'';
```

Or read from `mesh-topology.nix` (after sec-03):

```nix
lib.ghaWireguardConfig = let
  mesh = import ../b_infra/_shared/mesh-topology.nix;
  hub = mesh.peers.gcp-proxy;
in pkgs.writeText "wg-gha.conf" ''
  [Interface]
  PrivateKey = RUNTIME_INJECTED

  [Peer]
  PublicKey = ${hub.publicKey}
  Endpoint = ${hub.endpoint}
  AllowedIPs = ${mesh.wgSubnet}
  PersistentKeepalive = 25
'';
```

### Peer declaration in mesh topology:

```nix
# In mesh-topology.nix (or wireguard.nix)
clients = {
  surface = { wgIp = "10.0.0.10"; };
  termux  = { wgIp = "10.0.0.11"; };
  gha     = { wgIp = "10.0.0.20"; };  # GHA runner
};
```

### SSH config swap to WG IPs:

When WG tunnel is up, engine uses WG IPs instead of public IPs. Declared in SSH config:

```yaml
- name: SSH config (WG)
  if: env.WG_PRIVATE_KEY != ''
  shell: bash
  run: |
    # Override VM hosts to use WG IPs (from mesh-topology)
    cat >> ~/.ssh/config <<'EOF'
    Host gcp-proxy
      Hostname 10.0.0.1
    Host oci-apps
      Hostname 10.0.0.6
    Host oci-mail
      Hostname 10.0.0.3
    Host oci-analytics
      Hostname 10.0.0.4
    EOF
```

**Dependency**: Cleaner after sec-03 (mesh-topology.nix as source of truth for WG IPs).

**Files**: `.github/flake.nix`, `.github/actions/setup-deps/action.yml`, `b_infra/_shared/wireguard.nix` or `mesh-topology.nix`

---

## Projected Savings

| Phase | Saves | Cumulative | New Total |
|-------|-------|------------|-----------|
| Baseline | — | — | ~220s |
| Phase 1: Nix cache | ~30s (sops + build) | 30s | ~190s |
| Phase 2: Deps flake | ~5s (single nix develop vs multiple nix-shell) | 35s | ~185s |
| Phase 3: SSH ControlMaster | ~20s | 55s | ~165s |
| Phase 4: rsync optimize | ~40s | 95s | ~125s |
| Phase 5: Hash-on-VM (no-change) | ~150s (full skip) | — | **~15s** |
| Phase 6: WG tunnel | ~30s more on rsync | 125s | **~95s** |

**No-change deploy**: **~15s** after Phase 5.
**Changed deploy**: **~60-95s** after all phases (down from 220s).

---

## Declarative Compliance

| Phase | Nix Way? | Notes |
|-------|----------|-------|
| Phase 1: Nix cache | Yes | GHA action caching nix store — no imperative installs |
| Phase 2: Deps flake | Yes | All tools declared in `.github/flake.nix`, single `nix develop` |
| Phase 3: SSH ControlMaster | Yes | Config in action.yml source |
| Phase 4: rsync flags | Yes | Engine source change in `_engine.sh` |
| Phase 5: Hash-on-VM | Yes | Engine-managed deploy state (written/read by pipeline only) |
| Phase 6: WG tunnel | Yes | `wireguard-tools` from deps flake, config generated from `mesh-topology.nix` |

**Zero `apt-get`, zero `curl` binary downloads, zero imperative installs. Everything from nix.**

---

## Implementation Order

1. **Phase 1 + 2** together — nix cache + deps flake (biggest bang, foundational)
2. **Phase 3** — SSH ControlMaster (easy, no deps)
3. **Phase 4** — rsync flags (easy, engine change)
4. **Phase 5** — hash-on-VM (medium, engine change — biggest skip-win)
5. **Phase 6** — WG tunnel (after sec-03 mesh-topology.nix)

---

## Files Modified

| File | Change |
|------|--------|
| `.github/flake.nix` | NEW — GHA build environment (sops, age, yq, wireguard-tools, rsync) |
| `.github/flake.lock` | NEW — generated from flake.nix |
| `.github/actions/setup-deps/action.yml` | Nix cache, `nix develop` instead of individual nix-shell, SSH ControlMaster, WG tunnel |
| `a_solutions/_engine.sh` | rsync flags, hash-on-VM, deps flake support |
| `b_infra/_shared/wireguard.nix` | Add GHA peer (10.0.0.20) |
