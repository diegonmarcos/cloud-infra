# GHCR Container Registry Integration

> **Date**: 2026-03-18
> **Updated**: 2026-03-18
> **Status**: TODO
> **Depends on**: TASK-sec-01 (engine v2 must support `docker.build: "local"`)
> **Replaces**: TASK-05

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
- [ ] Update service's docker-compose.yml: `build:` -> `image: ghcr.io/...`
- [ ] Update service's flake.nix to generate the new compose format
- [ ] Test full cycle: push -> GHA build -> GHCR -> VM pull -> running

### Rollout
- [ ] Migrate bb-sec_rust-api to GHCR
- [ ] Migrate bc-obs_rig to GHCR
- [ ] Remove `REMOTE_BUILD` flag from all GHA workflows
- [ ] Update engine `ship` command: push to GHCR instead of rsync + remote build

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
push to main -> GHA SSH into VM -> rsync source -> docker build ON the VM -> docker compose up
```

Problems:
- Builds consume VM CPU/RAM (especially bad on e2-micro 1GB)
- SSH unresponsive during builds
- Build tools must be installed on every VM
- Cross-compilation issues (x86_64 runner -> aarch64 VM)

## Target Workflow (GHCR)

```
push to main -> GHA builds image -> docker push ghcr.io/diegonmarcos/<service>:latest
             -> GHA SSH into VM -> docker compose pull -> docker compose up -d
```

**Note**: With engine v2 (TASK-sec-01), this becomes `docker.build: "local"` in build.json + GHCR push. The engine handles the rest.

---

## GHA Template

```yaml
- name: Log in to GHCR
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

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

---

## Services Using REMOTE_BUILD (Migration Candidates)

| Service | VM | Arch |
|---------|-----|------|
| bc-obs_c3-mcp-api | oci-apps | aarch64 |
| bb-sec_rust-api | oci-apps | aarch64 |
| bc-obs_rig | oci-apps | aarch64 |

---

## Considerations

- **Image visibility**: Default to private; make public only if intentional
- **Image size**: Use multi-stage Dockerfiles to keep images small
- **Caching**: Use GHA cache with `docker/build-push-action` for faster builds
- **Versioning**: Start with `:latest`, consider `:<sha>` tags later
- **VM auth**: Store GHCR token in sops secrets, deploy via home-manager activation
