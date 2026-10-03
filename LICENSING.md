# Licensing map — cloud-infra

> Not legal advice. This is an inventory of what the tree contains and which licence each part
> carries today, written so the owner (and a lawyer, if needed) can decide from facts.

The machine-readable half is [`licenses/`](./licenses):

| File | What it is | Written by |
|---|---|---|
| `licenses/curated.json` | licence of every top-level directory and of every directory that carries a LICENSE file; licences of flake inputs, container images and Terraform providers (read from each upstream's LICENSE file, never guessed) | hand |
| `licenses/upstreams.json` | in-tree forks / vendored upstream source, with pins — **empty: this repository holds none** | hand |
| `licenses/inventory.json` | every subject the tree builds from, each with its licence and where it is declared | `python3 9_others/src/licence-inventory.py refresh .` |

CI: `licence-inventory-guard.yml` runs `licence-inventory.py check .` on every push (no path filter)
and fails, naming it, when something new appears with no entry. Its tester
`9_others/test/test_licence_inventory_guard.sh` breaks the inventory 17 ways on a fixture repo
(must-fail), makes 5 changes that must stay green (version/tag/digest bumps among them), and runs
6 mutants of the guard that must each turn the suite red.

## 1. The licence of this repository's own code

The original code here is licensed under the **PolyForm Noncommercial License 1.0.0**
([`LICENSE`](./LICENSE), SPDX `PolyForm-Noncommercial-1.0.0`; its source is `0_git/src/LICENSE`,
copied verbatim to the root by `9_others/build.sh`). Plain English: free to use, copy, modify and
share for any **noncommercial** purpose; commercial use is not granted without a separate licence.
It is source-available, not OSI "open source".

That licence covers the owner's own work: the Nix flakes and Home-Manager configurations
(`b_infra/`), the build/ship engines and workflows (`1_cicd/`, `9_others/`, `build.sh`), the
generated configuration (`1_cloud-configs/`), the Terraform (`c_vps/`), docs, tasks and reports.
Nothing in this change alters `LICENSE`. Whether the fleet keeps PolyForm-NC, or moves to another
licence, is the owner's decision under #815.

Contact for commercial licensing: Diego Nepomuceno Marcos — <https://diegonmarcos.com>.

## 2. What the root licence does NOT cover

| Part | Licence | Note |
|---|---|---|
| `z_archive/**` | each file's own | Archived material, outside the inventory (`scan_skip_prefixes`). Its only foreign licence files are mdBook font files (Open Sans Apache-2.0, Source Code Pro OFL-1.1) under three archived services' `dist/docs/fonts/`. Never relicensed by the root `LICENSE`. |
| `I_cloud` (submodule) | that repository's own | The read-only fleet index, a gitlink, not files of this tree. |
| Container services | their upstream licences | Since 2026-09-06 the per-service source (`a_solutions/`) lives in **cloud-u-containers**, which has its own `LICENSING.md` and inventory. |
| Everything fetched at build time | its upstream licence | flake inputs and every Nix package built from them, container base images, Terraform providers, npm / PyPI packages - section 3. Not relicensed. |

## 3. Third-party dependencies (from `licenses/inventory.json`, 39 subjects)

| Kind | Subjects | Licences |
|---|---|---|
| Top-level directories | 23 incl. `licenses/` (+ `0_git/src`, `0_git/dist` holding the licence text) | all own, PolyForm-NC |
| Flake inputs | `nixpkgs`, `home-manager` | MIT (the Nix expressions; each package keeps its own `meta.license`) |
| Flake inputs (own) | this repo's `config.json` fetched as a non-flake input | own |
| Container base image | `debian` (vm-pilot transport image) | per-package Debian licences |
| Terraform providers | aws, google, google-beta, oci, resend | MPL-2.0 |
| | cloudflare | Apache-2.0 |
| npm (`1_cloud-configs/src/derive`) | ajv, ajv-formats | MIT |
| | yaml | ISC |
| PyPI (billing-disabler Cloud Function) | google-cloud-billing | Apache-2.0 |

Transitive dependencies are **not** resolved (that needs a Nix / npm / pip resolution the shared
runners do not run for an audit); each package entry says so. No in-tree forks, so no provenance
(upstream-derived vs newly authored) measurement applies to this repository.

## 4. Conflicts and gaps

| # | Finding | Evidence | Fix |
|---|---|---|---|
| 1 | The previous `LICENSING.md` described `a_solutions/*` carve-outs that no longer exist here | split to cloud-u-containers on 2026-09-06 | corrected in this file |
| 2 | Nix configurations pull hundreds of packages via `nixpkgs`; their licences (GPL, LGPL, MIT, some unfree-redistributable) are only visible per package | `b_infra/*/src/flake.nix` | nothing to do while the hosts only *run* them; a published image / closure would need a `nix-store --query` licence report |
| 3 | `z_archive/` holds third-party fonts (Apache-2.0 / OFL-1.1) inside a PolyForm-NC repository; they are excluded from the inventory | `z_archive/*/dist/docs/fonts/*-LICENSE.txt` | keep the licence files beside the fonts; delete the archive if it is no longer reference material |
| 4 | Terraform providers are MPL-2.0 (file-level copyleft) | `licenses/inventory.json` `tf:*` | none: they are used, not modified or redistributed |

## 5. Keeping it true

- Adding a dependency, flake input, image, provider, top-level directory or a directory with a
  LICENSE file turns `licence-inventory-guard` red until it is recorded: add any curated licence
  to `licenses/curated.json`, then `python3 9_others/src/licence-inventory.py refresh .` and commit
  `licenses/inventory.json` in the same push.
- If an upstream's source is ever vendored into this tree, record it in `licenses/upstreams.json`
  with its pinned revision and run `python3 9_others/src/licence-provenance.py .`.
