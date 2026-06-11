# Licensing

The original code in this repository is licensed under the **PolyForm
Noncommercial License 1.0.0** (see [`LICENSE`](./LICENSE)). SPDX:
`PolyForm-Noncommercial-1.0.0`.

**Plain English:** free to use, copy, modify, and share for any **noncommercial**
purpose; **commercial use is not granted** without a separate license. This is a
**source-available** license, not OSI "open source" / FSF "free software".

## What the root license covers

All the licensor's own work: the Nix flakes, `build.sh`/`build.json` engine,
`1_workflows/`, `2_configs/`, `3_secrets/`, and the per-service source under
`a_solutions/*/src/` that is original to this project.

## Carve-outs (NOT under the noncommercial license)

These retain their own upstream licenses and are **not** relicensed:

| Path | License | Note |
|------|---------|------|
| `a_solutions/z_archive/**` | per-upstream | Archived/abandoned vendored third-party code (e.g. the Roundcube **calendar** plugin is GPL/AGPL). Kept for reference only; governed by each file's own license, never by the root `LICENSE`. |
| any service that **vendors** a third-party upstream into `src/` | per-upstream | A service that bundles GPL/AGPL/Apache/etc. source ships under that upstream's license for those files. Declared per service in its `build.json`. |
| pulled container images / build caches (`*.cargo-home/`, fetched layers) | per-upstream | Third-party binaries fetched at build time; not relicensed. |

Services delivered as **GHCR images of third-party software** (Authelia, Caddy,
Gitea, Matomo, etc.) are the upstream projects' own works under their own
licenses; only the *configuration/flake* around them is the licensor's.

Contact for commercial licensing: Diego Nepomuceno Marcos —
<https://diegonmarcos.com>.

> Not legal advice.
