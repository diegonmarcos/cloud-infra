// derive-build-workflows.ts
//
// Reads 1_workflows/build.json (source-of-truth for the runner-image registry)
// and emits dist/build-workflows.json — the file consumed by:
//
//   • 1_workflows/src/scripts/cloud-ship-ci-builder-dispatch.sh
//   • 1_workflows/src/scripts/cloud-ship-container-step-build-docker.sh
//   • 1_workflows/src/libs/cloud-paths.sh
//   • 1_workflows/src/cicd/lint-pipeline.yml
//   • 1_workflows/src/test/test_runners_*.sh
//   • 1_workflows/src/test/test_arch_runner_routing.sh
//   • 1_workflows/src/test/test_no_hardcoded_builder_image_literals.sh
//
// Pattern mirrors every other build-{container}.json: consumers reach this
// file via the symlink 1_workflows/src/build-workflows.json →
// ../../2_configs/dist/build-workflows.json (FIRE-RULE 6 — no hardcoded
// inline data; the registry lives in build.json, the dist file is derived).
//
// Replaces the legacy cloud-data-runners.json import path (Step 3,
// 2026-05-09 migration). The legacy file is archived under I_cloud-data/z_archive/.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join, dirname } from "node:path";

const ENGINE_DIR = import.meta.dirname!;
const CONFIGS_DIR = resolve(ENGINE_DIR, "../..");
const CLOUD_ROOT = process.env.CLOUD_ROOT ?? resolve(CONFIGS_DIR, "..");
const DIST_DIR = join(CONFIGS_DIR, "dist");

const SRC_BUILD_JSON = join(CLOUD_ROOT, "1_workflows", "build.json");
const OUT_FILE = join(DIST_DIR, "build-workflows.json");

function read(p: string): any {
  return JSON.parse(readFileSync(p, "utf8"));
}

function main(): void {
  const src = read(SRC_BUILD_JSON);
  if (!src || typeof src !== "object") {
    throw new Error(`derive-build-workflows: ${SRC_BUILD_JSON} is not an object`);
  }
  if (!src.runners || typeof src.runners !== "object") {
    throw new Error(
      `derive-build-workflows: ${SRC_BUILD_JSON} is missing required 'runners' field`,
    );
  }

  // Extract only the workflow-engine concerns (runners + probe + dispatch).
  // Identity fields (name/description/build/deploy) belong to build.json,
  // not to the dist consumer surface. Docstrings live as sibling
  // `runners_doc` / `dispatch_doc` keys (NOT inside the maps), so consumer
  // jq queries like `.runners | to_entries[]` are not polluted by string
  // values and the schema validator doesn't see phantom entries.
  const out = {
    _comment:
      "Derived by 2_configs/src/engines/derive-build-workflows.ts from 1_workflows/build.json. Do not edit — edit the source.",
    _source: "1_workflows/build.json",
    _generated_at: (() => {
      // Reproducible timestamp — see cloud-data-config-derive.ts:`now`.
      const _sde = process.env.SOURCE_DATE_EPOCH;
      return (_sde && /^\d+$/.test(_sde))
        ? new Date(Number(_sde) * 1000).toISOString()
        : new Date().toISOString();
    })(),
    name: src.name,
    runners_doc: src.runners_doc,
    runners: src.runners,
    probe: src.probe,
    dispatch_doc: src.dispatch_doc,
    dispatch: src.dispatch,
  };

  mkdirSync(dirname(OUT_FILE), { recursive: true });
  writeFileSync(OUT_FILE, JSON.stringify(out, null, 2) + "\n", "utf8");
  console.log(`derive-build-workflows: wrote ${OUT_FILE}`);
}

main();
