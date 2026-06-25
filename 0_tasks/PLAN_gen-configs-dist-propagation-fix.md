# PLAN — gen-configs dist propagation fix (wg-public `surface` peer never deploys)

> Status: **PROPOSAL / for review** — no live runs performed. Author: deep-dive 2026-06-25.
> Scope: `ship-gen-configs` CI → cloud-builder derive → commit handoff. High blast radius
> (regenerates **every** VM's config), so this is written up rather than hot-applied.

---

## 1. Symptom

Adding a wg-public client (`surface`, 10.1.0.5) to the SoT
(`a_solutions/infra-net_wireguard-public/build.json` → `wireguard_public.clients`)
and its vault keypair (`vault/A0_keys/providers/wireguard/surface-public/`) does **not**
result in the peer being deployed to the hub (`oci-analytics` wg-public). The peer never
appears in `sudo wg show wg-public` on the hub; the desktop's `wg-public` handshake never
completes (`0 B received`).

## 2. Why it fails (root cause — evidenced)

The HM build excludes wg-public peers whose `wg_public_key` is `null`
(`b_infra/_shared/vm-pilot/src/modules/network/wireguard.nix`: *"Peers with null keys are
excluded later when generating [Peer] blocks"*). So the question is **why surface's key is
null in the committed cloud-data the HM build reads** — when every upstream input is correct:

| Check | Result |
|---|---|
| SoT `build.json` lists `clients.surface` | ✅ present (origin/main) |
| vault `surface-public/publickey` on **GitHub** | ✅ present (`git cat-file -e <ghmain>:…` → PRESENT), == `hG1x8b4J…` |
| Consolidator logic (`cloud-data-config-consolidated.ts`) | ✅ correct — `vaultWgKeys[<name>-public]` scan is generic |
| **Local** `2_configs/build.sh consolidate` on my vault | ✅ emits `surface=hG1x8b4JXsD0r0TXVD…` (REAL) |
| CI gen-configs sees the vault | ✅ log: `vault/wireguard: 15 public keys` (same count as local) |
| CI gen-configs runs the full pipeline | ✅ log: `Using engine: 2_configs/build.sh all` → `Consolidating → /root/git/cloud/2_configs/dist/_cloud-data-consolidated.json` |
| **Committed** canonical `2_configs/dist/_cloud-data-consolidated.json` | ❌ `surface=NULL` (termux/.10/.11 = REAL) |
| gen-configs commit step | ❌ "dist/ unchanged — nothing to commit" |

Everything required to produce `surface=REAL` is present in CI, and CI even logs that it
runs the consolidate — yet the committed file stays NULL and the commit no-ops.

### The handoff bug

`ship-gen-configs.yml` → "Generate inside cloud-builder":

```
docker compose -f /tmp/cloud-builder-compose.yaml run --rm \
  --cap-add NET_ADMIN \
  -v "$HOME/git/vault:/root/git/vault:ro" \
  -e CLOUD_DATA_DEPLOY_KEY \
  cloud-builder gen-configs
```

- `cloud-builder gen-configs` → `cloud-ship-orchestrate-gen-configs.sh` → `build.sh config`
  → `cloud-ship-repo-config-gen.sh` → **`bash $CLOUD_ROOT/2_configs/build.sh all`**.
- `$CLOUD_ROOT` inside the container is the **image-baked** `/root/git/cloud`, which the
  entrypoint **`git fetch origin main && reset --hard origin/main`** before running
  (`cb_containers-builders/src/docker/entrypoint.sh`).
- `compose.yaml` mounts **only** docker.sock + `/mnt/host-{ssh,sops,gh}` (`:ro`) + docker
  config; the `docker run` adds `/root/git/vault:ro`. **The runner's cloud checkout
  (`$GITHUB_WORKSPACE`) is never mounted into the container.**
- The container is **`--rm`**.

So the derive writes the fresh `2_configs/dist/` (with `surface=REAL`) into the **container's
ephemeral** `/root/git/cloud/2_configs/dist`, which is **discarded on container exit**. The
workflow's next step —

```
git add 2_configs/dist/ b_infra/_shared/vm-pilot/dist/ b_infra/nixhm-sudo-*/dist/ \
        a_solutions/*/src/_cloud-data-consolidated.json
```

— stages the **runner's** `$GITHUB_WORKSPACE` checkout, which the container never touched →
**"nothing to commit"**. Net: **gen-configs can never commit a cloud-repo dist change**; the
committed dist is a frozen snapshot from whenever propagation last worked, so any cloud-data
added since (the `surface` peer, and likely others) never reaches origin → the HM build reads
stale data → null-key peer dropped.

> Corollary already observed: the committed per-VM consolidated
> (`b_infra/nixhm-sudo-oci-analytics/dist/pilot/_cloud-data-consolidated.json`) is missing the
> whole `native.wireguard_public` section — same frozen-snapshot cause.

## 3. Fix options

### Option A (recommended) — mount the runner checkout, skip the in-container reset
Run the derive directly against the runner's `$GITHUB_WORKSPACE` so its output lands in the
checkout the commit step stages.

- In `ship-gen-configs.yml`, add to the `docker compose run`:
  `-v "$GITHUB_WORKSPACE:/root/git/cloud"` (read-write) and an env flag e.g.
  `-e CLOUD_REPO_MOUNTED=1`.
- In `entrypoint.sh`, **skip the `fetch/reset --hard origin/main` for `/root/git/cloud` when
  `CLOUD_REPO_MOUNTED=1`** (the runner already checked out the correct `head_sha`; a reset
  would discard the workspace state and re-introduce the staleness). Keep resets for the
  *other* baked repos.
- Pros: derive writes straight into the committed checkout; no copy step; the runner's
  `head_sha` is honoured. Cons: entrypoint conditional; ensure file ownership (container runs
  as root → `git add` on runner is fine, but `Post Run checkout` cleanup may need
  `chown`/`safe.directory`).

### Option B (smallest diff) — extract dist out of the container
Keep the container hermetic; copy its regenerated dist back to the runner before committing.

- Use a writable **output mount** for just the dist trees, e.g.
  `-v "$GITHUB_WORKSPACE/2_configs/dist:/root/git/cloud/2_configs/dist"` (+ the
  `b_infra/**/dist`, `a_solutions/*/src/_cloud-data-consolidated.json` targets), **and** make
  the entrypoint reset use `git checkout -- :/` / `clean -fdx -e <mounted dirs>` so it does
  **not** clobber the mounted output dirs.
- Or, no mounts: after `docker compose run`, `docker cp <container>:/root/git/cloud/2_configs/dist/. 2_configs/dist/` (requires a non-`--rm` run + explicit name + cleanup).
- Pros: container stays on its own clone (closest to today). Cons: the reset-vs-mount
  interaction is fiddly; partial-tree mounts are error-prone.

### Option C — container commits+pushes the cloud dist itself
The container already gets `-e CLOUD_DATA_DEPLOY_KEY` and pushes cloud-data; give it a cloud
deploy key and have the engine commit+push `2_configs/dist` + `b_infra/**/dist` from inside.
- Pros: self-contained. Cons: two writers to `main` (container + workflow), `[skip ci]`
  discipline, and it pushes from the container's reset-to-origin clone (must re-fetch to avoid
  non-fast-forward). Most moving parts — not preferred.

**Recommendation: Option A.** It removes the discard entirely and matches the workflow's
existing "read committed `head_sha`" model. Smallest conceptual surface; the only subtlety is
gating the entrypoint reset.

## 4. Test plan (a task isn't done without a tester)

1. **Unit (local, already green):** `cd 2_configs && bash build.sh all` → assert
   `jq '.native.wireguard_public.clients.surface.wg_public_key' dist/_cloud-data-consolidated.json`
   == `hG1x8b4J…` (REAL). ✅ confirmed during the dive.
2. **Pipeline (the fix):** dispatch `ship-gen-configs`; assert it now produces a **commit**
   (not "nothing to commit") and that `git show origin/main:2_configs/dist/_cloud-data-consolidated.json`
   + `…/b_infra/nixhm-sudo-oci-analytics/dist/pilot/_cloud-data-consolidated.json` both carry
   `surface=hG1x8b4J…`.
3. **End-to-end:** `ship-home-manager -f vm=oci-analytics` (now lands gen N+1 with surface —
   the activation-retry fix `dc5cb8c51` already makes the activation survive tunnel drops);
   then on the hub `sudo wg show wg-public allowed-ips | grep 10.1.0.5` and on the desktop
   `sudo wg show wg-public` shows a fresh handshake + `ping 10.1.0.1` succeeds.
4. **Regression:** confirm an unrelated VM (e.g. gcp-proxy) still gets a correct config and no
   spurious diff (the commit should contain exactly the intended cloud-data delta).

## 5. Blast radius / rollback
- Touches the config-generation pipeline that feeds **all** VMs' HM. A bad mount/reset could
  (a) commit a wrong/empty dist or (b) clobber the runner checkout.
- Mitigation: land Option A behind the `CLOUD_REPO_MOUNTED` flag (default off → today's
  behaviour) and exercise via `workflow_dispatch` first; inspect the resulting commit diff
  **before** allowing the cascade to `ship-home-manager` (the existing `b_infra/**` path-gate
  already limits HM auto-deploy).
- Rollback: revert the workflow + entrypoint change; cloud-builder entrypoint resets to
  origin on next run, so no VM state is stranded.

## 6. Related findings (out of scope here, noted for completeness)
- **Shipped:** `fix(ship-hm): retry HM activation on transient SSH tunnel drop (exit 255)`
  (`dc5cb8c51`) — wraps the activation SSH in a 255-retry; first time oci-analytics activated
  a new generation (91→92) in weeks.
- **B (job red despite gen switch):** the post-"Activating generation" cleanup steps
  (`nix-env --delete-generations` / GC over SSH, `cloud-ship-nix-homemanager-step-deploy-activate.sh`
  lines ~500-528) sit outside the retry wrapper and can still drop the tunnel. Cheap follow-up:
  wrap those in the same 255-retry, or make them non-fatal (they already `|| true` individually,
  but a mid-stream drop surfaces as the step's 255).
- The `workflow_run` cascade path-gate (`ship-home-manager.yml` lines ~89-97) only fires HM on
  `b_infra/**` changes; a wg-public *client* add changes `2_configs/dist` (+ once Option A
  lands, `b_infra/**/dist`), so verify the gate still triggers — it should, since Option A makes
  gen-configs commit the `b_infra/**/dist` delta.
