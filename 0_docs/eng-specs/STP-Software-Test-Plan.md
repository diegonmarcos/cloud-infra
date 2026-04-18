# STP — Software Test Plan (IEEE 829)

> Cloud Infrastructure as Code — Diego Nepomuceno Marcos

---

## 1. Test Plan Identifier

**STP-CLOUD-001** | Version 1.0 | 2026-04-15

---

## 2. Introduction

This test plan covers verification and validation of the Cloud IaC platform: build engine, service deployments, networking, security, and observability.

---

## 3. Test Items

| Item | Version | Location |
|------|---------|----------|
| Build Engine | current | `a_solutions/_engine.sh` |
| Service Flakes | per-service | `a_solutions/*/src/flake.nix` |
| Cloud-Data Engines | current | `I_cloud-data/engines/` |
| Home Manager Modules | current | `b_infra/home-manager/_shared/modules/` |
| CI/CD Workflows | current | `.github/workflows/` |
| MCP Servers | current | `bc-obs_c3-infra-*/`, `bc-obs_cloud-cgc-mcp/` |

---

## 4. Features to Test

### 4.1 Build Pipeline
- [ ] `build.sh build` produces deterministic `dist/` output
- [ ] `build.sh secrets` decrypts SOPS secrets to `.secrets` env file
- [ ] `build.sh deploy` rsyncs to correct VM and path
- [ ] `build.sh compose` starts containers on target VM
- [ ] `build.sh ship` executes full pipeline end-to-end
- [ ] `build.sh clean` removes all build artifacts

### 4.2 Service Health
- [ ] All 59 services have valid `build.json`
- [ ] All services with domains are reachable via HTTPS
- [ ] All services behind Authelia require 2FA
- [ ] Bearer token authentication works for API endpoints

### 4.3 Networking
- [ ] WireGuard mesh connectivity between all 5 VMs
- [ ] Hickory DNS resolves `*.app` zones over WireGuard
- [ ] Caddy routes match cloud-data-caddy-routes.json
- [ ] Cloudflare → Caddy → WG → container path works

### 4.4 Security
- [ ] No plaintext secrets in git history
- [ ] SOPS decryption works with age key
- [ ] Authelia 2FA enforced on all public endpoints
- [ ] SSH key-only authentication (no passwords)
- [ ] Firewall rules match cloud-data-firewall-rules.json

### 4.5 Cloud-Data Generation
- [ ] `cloud-data-config-derive.ts` produces all 26 JSON files
- [ ] Output matches `manifest.json` index
- [ ] Per-VM container specs are accurate
- [ ] Caddy routes, Authelia ACLs, DNS records are consistent

### 4.6 Home Manager
- [ ] HM builds for all 5 VMs (4 x86_64, 1 aarch64)
- [ ] System protection modules activate correctly
- [ ] Container-init starts Docker containers in correct order
- [ ] Watchdog + health agent are operational

### 4.7 MCP Servers
- [ ] `c3-infra-mcp` responds to all 70+ tools
- [ ] `cloud-cgc-mcp` knowledge queries return accurate data
- [ ] Health tier1/tier2/tier3 checks pass
- [ ] Topology drift detection works

---

## 5. Testing Approach

| Level | Method | Tool |
|-------|--------|------|
| Unit | Nix build evaluation | `nix build --dry-run` |
| Integration | End-to-end deploy | `build.sh ship` to staging |
| Health | Automated checks | C3 API `health_tier1/2/3` |
| Security | Secret scanning | `git log --all -p \| grep -i secret` |
| Regression | Cloud-data diff | Compare JSON output before/after changes |
| Acceptance | MCP tool execution | Claude agent runs all MCP tools |

---

## 6. Pass/Fail Criteria

| Criteria | Threshold |
|----------|-----------|
| Service health | 100% of deployed services respond |
| Build success | All 59 services build without errors |
| Security | 0 plaintext secrets in git |
| Cloud-data | 26/26 JSON files generated |
| WireGuard | All 5 VMs reachable over mesh |

---

## 7. Testing Tools

| Tool | Purpose |
|------|---------|
| C3 API | Health checks, topology verification |
| DTK (`II_tools/`) | Operational diagnostics |
| `nix build` | Derivation validation |
| `sops -d` | Secrets decryption test |
| `curl` + Bearer token | API endpoint testing |
| GHA `health.yml` | Scheduled health monitoring |
