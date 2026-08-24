// derive-build-workflows.ts
//
// Reads 1_cloud-configs/build.json (probe/dispatch config, plus name) and
// 1_cloud-configs/src/inputs/cloud-builders-runner.json (dedicated source-of-truth for
// runner topology — its `.runners` takes precedence over build.json's own
// `.runners` when the file is present; falls back to build.json's
// `.runners` unchanged if it is absent), and emits dist/build-workflows.json
// — the file consumed by:
//
//   • 1_cicd/src/scripts/cloud-ship-ci-builder-dispatch.sh
//   • 1_cicd/src/scripts/cloud-ship-container-step-build-docker.sh
//   • 9_others/src/cloud-paths.sh
//   • 1_cicd/src/cicd/lint-pipeline.yml
//   • 9_others/test/test_runners_*.sh
//   • 9_others/test/test_arch_runner_routing.sh
//   • 9_others/test/test_no_hardcoded_builder_image_literals.sh
//
// Pattern mirrors every other build-{container}.json: consumers reach this
// file via the symlink 9_others/src/build-workflows.json →
// ../../1_cloud-configs/dist/build-workflows.json (FIRE-RULE 6 — no hardcoded
// inline data; the registry lives in cloud-builders-runner.json, the dist
// file is derived).
//
// Replaces the legacy cloud-data-runners.json import path (Step 3,
// 2026-05-09 migration). The legacy file is archived under I_cloud-data/z_archive/.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, join, dirname } from "node:path";

const ENGINE_DIR = import.meta.dirname!;
const CONFIGS_DIR = resolve(ENGINE_DIR, "../..");
const CLOUD_ROOT = process.env.CLOUD_ROOT ?? resolve(CONFIGS_DIR, "..");
const DIST_DIR = join(CONFIGS_DIR, "dist");

const SRC_BUILD_JSON = join(CLOUD_ROOT, "1_cloud-configs", "build.json");
const SRC_RUNNERS_JSON = join(CLOUD_ROOT, "1_cloud-configs", "src", "inputs", "cloud-builders-runner.json");
const OUT_FILE = join(DIST_DIR, "build-workflows.json");

function read(p: string): any {
  return JSON.parse(readFileSync(p, "utf8"));
}

function main(): void {
  const src = read(SRC_BUILD_JSON);
  if (!src || typeof src !== "object") {
    throw new Error(`derive-build-workflows: ${SRC_BUILD_JSON} is not an object`);
  }

  // Runner topology precedence: cloud-builders-runner.json is the dedicated
  // source of truth (extracted 2026-08-09) and, when present, its `.runners`
  // replaces build.json's own `.runners` entirely in the emitted dist file.
  // Falls back to build.json's `.runners` — unchanged behaviour — if the
  // dedicated file doesn't exist yet in a given checkout.
  const hasRunnersFile = existsSync(SRC_RUNNERS_JSON);
  const runnersSrcPath = hasRunnersFile ? SRC_RUNNERS_JSON : SRC_BUILD_JSON;
  const runners = hasRunnersFile ? read(SRC_RUNNERS_JSON).runners : src.runners;
  if (!runners || typeof runners !== "object") {
    throw new Error(
      `derive-build-workflows: ${runnersSrcPath} is missing required 'runners' field`,
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
      "Derived by 1_cloud-configs/src/derive/derive-build-workflows.ts from 1_cloud-configs/build.json (name/probe/dispatch) and 1_cloud-configs/src/inputs/cloud-builders-runner.json (runners, when present — falls back to build.json's .runners otherwise). Do not edit — edit the source.",
    _source: "1_cloud-configs/build.json + 1_cloud-configs/src/inputs/cloud-builders-runner.json",
    // Stable empty string — see cloud-data-config-derive.ts:`now`.
    _generated_at: "",
    name: src.name,
    runners_doc: src.runners_doc,
    runners,
    probe: src.probe,
    dispatch_doc: src.dispatch_doc,
    dispatch: src.dispatch,
  };

  mkdirSync(dirname(OUT_FILE), { recursive: true });
  writeFileSync(OUT_FILE, JSON.stringify(out, null, 2) + "\n", "utf8");
  console.log(`derive-build-workflows: wrote ${OUT_FILE}`);

  registerInManifest();
}

// This deriver runs after cloud-data-config-derive has already written the
// manifest, so it appends itself rather than being declared there — the
// manifest is what the orphan prune treats as the full set of pipeline
// outputs, and an unregistered file would be swept as stale.
function registerInManifest(): void {
  const manifestFile = join(CONFIGS_DIR, "manifest.json");
  if (!existsSync(manifestFile)) return;

  const entry = { file: "dist/build-workflows.json", name: "build workflows" };
  const manifest = JSON.parse(readFileSync(manifestFile, "utf8"));
  if (!Array.isArray(manifest)) return;
  if (manifest.some((e: any) => e?.file === entry.file)) return;

  manifest.push(entry);
  writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + "\n", "utf8");
}

main();
