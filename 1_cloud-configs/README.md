# 1_cloud-configs — the derive job

Reads declarations, writes derived JSON. That is the whole remit.

```
src/
  derive/     TypeScript engines + parsers/ — consolidate then derive
  inputs/     hand-authored data: builds/ (one symlink per service build.json),
              external-consumers.json, cloud-builders-runner.json,
              github-repos.json, reports-*.json, hm-config.json, notify-policy.json
  derivers.json   ordered deriver registry — adding one is a JSON edit
  test/       the derive suite (test-*.sh)
dist/         build-*.json, _cloud-data-consolidated.json, mesh-snapshot.json,
              code-signatures-cloud.json, build-workflows.json, cloud-fleet-*.json
build.sh      link-builds | consolidate | derive | test | clean | all | ship
```

## What is deliberately NOT here

No `.git*`, no `.github/` workflows, no editor dotfiles. Those are
repo-universal and live in `1_configs/`, which every one of the repos carries
as the same module. This split happened on 2026-08-10; before it, one module
held both and its `dist/` had two writers — which is why its purge step had to
hand-list the subtrees it owned, and why retired services' `build-*.json`
lingered for months (24 of them, found during the split).

## Dependency direction

`1_cloud-configs` sources shared shell libs from `1_configs/src/lib/`
(engine-traps, ensure-deps, cloud-paths). The dependency runs one way only:
1_configs never reads anything from here.

## Consumers

Services symlink their own `build-<name>.json` from `dist/` into
`a_solutions/<service>/src/`. Five fleet-wide MCP services link all of them.
`link_builds` regenerates the input side; lint Phase 4 fails loudly if any
symlink dangles.
