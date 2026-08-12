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
| **Local** `9_others/build.sh consolidate` on my vault | ✅ emits `surface=hG1x8b4JXsD0r0TXVD…` (REAL) |
| CI gen-configs sees the vault | ✅ log: `vault/wireguard: 15 public keys` (same count as local) |
| CI gen-configs runs the full pipeline | ✅ log: `Using engine: 9_others/build.sh all` → `Consolidating → /root/git/cloud/1_cicd/dist/_cloud-data-consolidated.json` |
| **Committed** canonical `1_cicd/dist/_cloud-data-consolidated.json` | ❌ `surface=NULL` (termux/.10/.11 = REAL) |
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
  → `cloud-ship-repo-config-gen.sh` → **`bash $CLOUD_ROOT/9_others/build.sh all`**.
- `$CLOUD_ROOT` inside the container is the **image-baked** `/root/git/cloud`, which the
  entrypoint **`git fetch origin main && reset --hard origin/main`** before running
  (`cb_containers-builders/src/docker/entrypoint.sh`).
- `compose.yaml` mounts **only** docker.sock + `/mnt/host-{ssh,sops,gh}` (`:ro`) + docker
  config; the `docker run` adds `/root/git/vault:ro`. **The runner's cloud checkout
  (`$GITHUB_WORKSPACE`) is never mounted into the container.**
- The container is **`--rm`**.

So the derive writes the fresh `1_cicd/dist/` (with `surface=REAL`) into the **container's
ephemeral** `/root/git/cloud/1_cicd/dist`, which is **discarded on container exit**. The
workflow's next step —

```
git add 1_cicd/dist/ b_infra/_shared/vm-pilot/dist/ b_infra/nixhm-sudo-*/dist/ \
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
  `-v "$GITHUB_WORKSPACE/1_cicd/dist:/root/git/cloud/1_cicd/dist"` (+ the
  `b_infra/**/dist`, `a_solutions/*/src/_cloud-data-consolidated.json` targets), **and** make
  the entrypoint reset use `git checkout -- :/` / `clean -fdx -e <mounted dirs>` so it does
  **not** clobber the mounted output dirs.
- Or, no mounts: after `docker compose run`, `docker cp <container>:/root/git/cloud/1_cicd/dist/. 1_cicd/dist/` (requires a non-`--rm` run + explicit name + cleanup).
- Pros: container stays on its own clone (closest to today). Cons: the reset-vs-mount
  interaction is fiddly; partial-tree mounts are error-prone.

### Option C — container commits+pushes the cloud dist itself
The container already gets `-e CLOUD_DATA_DEPLOY_KEY` and pushes cloud-data; give it a cloud
deploy key and have the engine commit+push `1_cicd/dist` + `b_infra/**/dist` from inside.
- Pros: self-contained. Cons: two writers to `main` (container + workflow), `[skip ci]`
  discipline, and it pushes from the container's reset-to-origin clone (must re-fetch to avoid
  non-fast-forward). Most moving parts — not preferred.

**Recommendation: Option A.** It removes the discard entirely and matches the workflow's
existing "read committed `head_sha`" model. Smallest conceptual surface; the only subtlety is
gating the entrypoint reset.

## 4. Test plan (a task isn't done without a tester)

1. **Unit (local, already green):** `cd 9_others && bash build.sh all` → assert
   `jq '.native.wireguard_public.clients.surface.wg_public_key' dist/_cloud-data-consolidated.json`
   == `hG1x8b4J…` (REAL). ✅ confirmed during the dive.
2. **Pipeline (the fix):** dispatch `ship-gen-configs`; assert it now produces a **commit**
   (not "nothing to commit") and that `git show origin/main:1_cicd/dist/_cloud-data-consolidated.json`
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
  `b_infra/**` changes; a wg-public *client* add changes `1_cicd/dist` (+ once Option A
  lands, `b_infra/**/dist`), so verify the gate still triggers — it should, since Option A makes
  gen-configs commit the `b_infra/**/dist` delta.

---

## 7. UPDATE 2026-06-25 — canonical fix landed; second gap found

**Shipped & verified:** the workspace-mount fix (`2c6dce0ca`) works — gen-configs now
**commits** (`d5b4652e4 ci(gen-configs): refresh dist/…`) and the committed **canonical**
`1_cicd/dist/_cloud-data-consolidated.json` now carries
`native.wireguard_public.clients.surface.wg_public_key = hG1x8b4J…` (REAL). Root cause #1 fixed.

**Second gap (still open):** the HM build reads the **per-VM**
`b_infra/nixhm-sudo-<vm>/dist/pilot/_cloud-data-consolidated.json`, a **committed regular file
dated Jun-10** that does *not* carry the wg-public section / surface. The propagation chain is:

```
1_cicd/dist/_cloud-data-consolidated.json            (canonical — now has surface)
  ▲ symlink  b_infra/_shared/modules/_cloud-data-consolidated.json
  ▲ symlink  b_infra/_shared/vm-pilot/src/modules/_cloud-data-consolidated.json   (src — current)
  ── cp -rL (step_build) ──▶  b_infra/nixhm-sudo-<vm>/dist/pilot/_cloud-data-consolidated.json
                              (per-VM dist — STALE Jun-10, what the HM flake reads)
```

`cloud-ship-nix-homemanager-step-pull-pilot.sh` only *checks* the `src/pilot` symlink; the actual
copy is `cp -rL` in **step_build**, which should resolve the symlink to the (now-surface) canonical.
Yet a fresh HM ship after the canonical fix produced **gen 93 with no surface** (and the job's
generation switched but content was identical to gen 92 → a no-op rebuild). So in CI the per-VM
`dist/pilot` consolidated the HM flake reads is NOT being refreshed from the fixed canonical.

**Hypotheses to check in a CI run (could not be done remotely):**
1. `step_build`'s `cp -rL` does not overwrite the committed `dist/pilot/_cloud-data-consolidated.json`
   (e.g. copies into a different path, or the flake reads the committed in-tree file directly).
2. The committed per-VM `dist/pilot` snapshot should not be a stale regular file at all — it should
   be a **symlink to the canonical** (like `_shared/modules/_cloud-data-consolidated.json` is), or be
   regenerated+committed by gen-configs (it currently isn't — `9_others/build.sh all` writes the
   canonical, not the per-VM `dist/pilot`).

**Likely fix (needs verification):** either (a) make `nixhm-sudo-<vm>/dist/pilot/_cloud-data-consolidated.json`
a symlink to `../../../1_cicd/dist/_cloud-data-consolidated.json` (always current, matches the
existing `_shared/modules` pattern), or (b) have gen-configs/step_build regenerate that per-VM file
from the canonical and commit it. Confirm by inspecting the file the HM `nix build` actually reads
(add a `cat`/`jq .native|keys` debug line to step_build for one run).

**Engine fixes shipped this investigation:**
- `dc5cb8c5` — retry HM activation on transient SSH tunnel drop (exit 255).
- `2c6dce0c` — mount runner workspace so gen-configs commits the regenerated dist (canonical fix).
