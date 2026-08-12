# Secrets cleanup — post-mortem (2026-04-21 → 2026-04-22)

Two issues were interleaved:
1. **`_credentials` secrets-convention work** — now shipped.
2. **Secret exposure incident** — 6 plaintext credentials leaked in public `origin/main` history; history purge complete.

---

## Status: ✅ Complete

### Phase S — Secret exposure cleanup (history purge)

| # | task | status |
|---|------|--------|
| S1 | Install `git-filter-repo` | ✅ already in nix profile |
| S2 | Tag `origin/main` as rollback anchor | ✅ `local-main-pre-purge-20260422T{124717,131412}Z` |
| S3 | `git clone --mirror` to a scratch dir | ✅ `/home/diego/.secrets-purge/cloud-purge-mirror.git` (removed after push) |
| S4 | Data-driven needle list | ✅ `/home/diego/.secrets-purge/{needles.txt,replace-text.txt,paths-to-remove.txt}` |
| S5 | `git filter-repo --paths-from-file --invert-paths` + `--replace-text` | ✅ executed via `/home/diego/.secrets-purge/purge.sh` |
| S6 | Verify 0 needle hits across full history | ✅ all 6 needles = 0 hits (fresh-clone tester) |
| S7 | `git fsck --full` | ⏭ skipped (0-hit verify sufficient) |
| S8 | Force-push cleaned mirror | ✅ `origin/main = dc6093b762b2…` |
| S9 | Delete stale `cleaned-main` branch | ✅ deleted; that branch was anchoring 3 leftover needle-bearing commits |
| S10 | GitHub cache purge / re-clone | ⏭ optional; 0-hit verification was done against a fresh bare clone |

**Needles purged (6):**
- `21dd4572b47aaf91fc5d3f9cabcc88f9e6e7984e`
- `hL6Fez-xT8CFo6njTAYiGuvpUN_Vl_blwFGm9t2Ah2s`
- `eyJhbGciOiJSUzI1NiIsImtpZCI6Im1haW4iLCJ0eXAiOiJhdCtqd3QifQ`
- `MatomoRoot2025!`
- `MatomoDB2025!`
- `x1NdureaBojGCVvkGuCKv1EDOn9JUham`

**File purged from history:** `a_solutions/aa-sui_tools-stalwart/src/secrets.yaml.new`

---

### Phase R — Reintegrate local work

| # | task | status |
|---|------|--------|
| R1-R6 | 14 secrets commits landed on `origin/main` | ✅ preserved through rewrite (subjects mapped to new SHAs) |
| R-extra | 10 commits landed on origin DURING the force-push — resurrected | ✅ cherry-picked via `/home/diego/.secrets-purge/resurrect.sh`; the one containing needles in the plan doc (`docs(plan): infra fix execution plan`) was redacted using the same replace-text.txt rules |
| R7 | VM sanity: `grep -l ^_ /opt/containers/*/.secrets` returns empty | ✅ verified 2026-04-22 on all 4 VMs (gcp-proxy, oci-mail, oci-analytics, oci-apps) |

### Phase U — `~/git/unix/` submodule

| # | task | status |
|---|------|--------|
| U1-U3 | `III_unix _credentials` commits pushed | ✅ on `origin/main` at `a0b8a20` |

---

## Pending

| # | task | priority | status |
|---|------|----------|---|
| L1 | Root-cause the silent `git reset --hard` wipe | — | ✅ investigated: no autonomous trigger found (no cron, no systemd timer, no `git sync` alias, no shell function). Git hooks at `0_git/dist/hooks/` only rebase submodules. If wipes recur, enable `.git/config` reflog tracing |
| L2 | Document in `~/.claude/CLAUDE.md`: long sessions must start with rescue tag + snapshot | low | ✅ added `E.1.2 Long Session Safety` to both `~/git/unix/{ba,bb}_flakes_*/src/modules/dotfiles/claude/CLAUDE.md`; deploys via `build.sh switch` |
| L3 | Verify `lint-secrets-coverage.yml` GHA workflow runs green on next PR | low | ⏳ workflow is correctly gated on `pull_request`; hasn't fired yet because all recent commits went to `main` directly. Will run on next PR |
| L4 | VM sanity check (= R7) | — | ✅ done (see R7) |
| L5 | Clone-scan for `*.yaml.new` / `*.bak` plaintext leftovers | low | ✅ zero hits in cloud tree |

**Rotation: out of scope, permanent.** The 6 credentials stay in production as-is per user direction. History purge is the only remediation.

---

## Recovery anchors

| ref | points at | notes |
|---|---|---|
| `local-main-pre-purge-20260422T131412Z` | `ba7ef706` (pre-rewrite tip) | local-only; keep for diffing old vs rewritten tree |
| `local-main-pre-purge-20260422T124717Z` | earlier pre-rewrite tip | redundant with the later one; can be deleted |
| `~/.backups/cloud-purge-rescue-20260422/*.{patch,tar.gz,txt}` | dirty working-tree snapshot | restores the 92 dirty paths present pre-purge if ever needed |
| `~/.secrets-purge/{needles,replace-text,paths-to-remove}.txt` | data-driven purge inputs | keep: documents exactly what was redacted |
| `~/.secrets-purge/{purge,resurrect}.sh` | declarative engines | re-runnable if another leak needs purging |

---

## Tester (reproducible)

```bash
cd /tmp && rm -rf _verify.git
git clone --bare --quiet git@github.com:diegonmarcos/cloud.git _verify.git
while IFS= read -r n; do
  [ -z "$n" ] && continue
  printf "%-55s %s hits\n" "$n" "$(git -C _verify.git log --all -S"$n" --oneline | wc -l)"
done < ~/.secrets-purge/needles.txt
rm -rf /tmp/_verify.git
# expected: 0 hits for every needle
```

Last run: **2026-04-22 — all 6 needles at 0 hits.** ✅
