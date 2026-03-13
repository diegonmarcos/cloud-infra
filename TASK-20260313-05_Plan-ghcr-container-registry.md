# TASK-05: GHCR Container Registry Integration

**Date**: 2026-03-13
**Status**: TODO
**Scope**: Replace `REMOTE_BUILD=true` with GHCR-based image delivery

---

## Checklist

### Setup
- [ ] Verify `GITHUB_TOKEN` has `write:packages` in GHA workflows
- [ ] Verify `ghcr.io/diegonmarcos` namespace works
- [ ] Set up VM-side GHCR auth (sops secret + home-manager activation)

### Pilot (one service)
- [ ] Pick pilot service (e.g., bc-obs_c3-mcp-api)
- [ ] Add GHCR login + build-push steps to GHA workflow
- [ ] Add multi-arch support (QEMU + Buildx) for aarch64
- [ ] Update service's docker-compose.yml: `build:` → `image: ghcr.io/...`
- [ ] Update service's flake.nix to generate the new compose format
- [ ] Test full cycle: push → GHA build → GHCR → VM pull → running

### Rollout
- [ ] Migrate bb-sec_rust-api to GHCR
- [ ] Migrate bc-obs_rig to GHCR
- [ ] Remove `REMOTE_BUILD` flag from all GHA workflows
- [ ] Update build.sh `ship` command: push to GHCR instead of rsync + remote build

### Cleanup
- [ ] Set up GHCR retention policy (prune old untagged images)
- [ ] Verify all services running from GHCR images
- [ ] Remove REMOTE_BUILD documentation references

---

## Why GHCR

- **Zero Maintenance**: No self-hosted registry to manage
- **Cost**: Free for public images; private images use GitHub account storage
- **Integration**: Native to GitHub Actions — build + push on every commit to `main`
- **Simpler VPS**: VMs only need `docker pull`, no source code or build tools required

## Current Workflow (REMOTE_BUILD)

```
push to main → GHA SSH into VM → rsync source → docker build ON the VM → docker compose up
```

Problems:
- Builds consume VM CPU/RAM (especially bad on e2-micro 1GB)
- SSH unresponsive during builds
- Build tools must be installed on every VM
- Cross-compilation issues (x86_64 runner → aarch64 VM)

## Target Workflow (GHCR)

```
push to main → GHA builds image → docker push ghcr.io/diegonmarcos/<service>:latest
             → GHA SSH into VM → docker compose pull → docker compose up -d
```

## Implementation Steps

### 1. GitHub Setup

- [ ] Use `GITHUB_TOKEN` in Actions (has `write:packages` by default)
- [ ] Verify `ghcr.io/diegonmarcos` namespace works

### 2. Manual Test (One Service)

```bash
# Authenticate
echo $GITHUB_TOKEN | docker login ghcr.io -u diegonmarcos --password-stdin

# Tag and push
docker tag my-service:latest ghcr.io/diegonmarcos/my-service:latest
docker push ghcr.io/diegonmarcos/my-service:latest
```

### 3. GitHub Action Template

```yaml
- name: Log in to GHCR
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

- name: Build and push
  uses: docker/build-push-action@v5
  with:
    context: a_solutions/<service>/dist
    push: true
    tags: ghcr.io/diegonmarcos/<service>:latest
```

### 4. Multi-Arch Builds (aarch64 + x86_64)

```yaml
- name: Set up QEMU
  uses: docker/setup-qemu-action@v3

- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v3

- name: Build and push (multi-arch)
  uses: docker/build-push-action@v5
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ghcr.io/diegonmarcos/<service>:latest
```

### 5. Update docker-compose.yml in Services

```yaml
# Before (local build)
services:
  my-service:
    build: .

# After (GHCR pull)
services:
  my-service:
    image: ghcr.io/diegonmarcos/my-service:latest
```

### 6. Update build.sh Pipeline

- `build` step: nix build → dist (unchanged)
- `ship` step: build image + push to GHCR + SSH `docker compose pull && docker compose up -d`
- Remove `REMOTE_BUILD` flag

### 7. VM-Side Auth (Private Images)

```bash
echo $GHCR_TOKEN | docker login ghcr.io -u diegonmarcos --password-stdin
```

Store token in sops secrets, deploy via home-manager activation script.

## Migration Order

1. Pick one simple service as pilot
2. Validate full cycle: push → GHA build → GHCR → VM pull → running
3. Roll out to remaining REMOTE_BUILD services
4. Remove REMOTE_BUILD logic from GHA workflows

## Services Using REMOTE_BUILD (Candidates)

| Service | VM | Arch |
|---------|-----|------|
| bc-obs_c3-mcp-api | oci-apps | aarch64 |
| bb-sec_rust-api | oci-apps | aarch64 |
| bc-obs_rig | oci-apps | aarch64 |

## Considerations

- **Image visibility**: Default to private; make public only if intentional
- **Image size**: Use multi-stage Dockerfiles to keep images small
- **Caching**: Use GHA cache with `docker/build-push-action` for faster builds
- **Versioning**: Start with `:latest`, consider `:<sha>` tags later
- **Cleanup**: Set up GHCR retention policy to prune old untagged images
