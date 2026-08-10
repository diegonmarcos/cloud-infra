// cloud-data-config.ts — Master orchestrator for cloud-data generation
//
// Runs the two stages sequentially:
//   1. cloud-data-config-consolidated.ts → writes _cloud-data-consolidated.json
//   2. cloud-data-config-derive.ts       → writes 17 per-consumer cloud-data-*.json
//
// Run: tsx cloud-data-config.ts
//
// Fails fast: if stage 1 exits non-zero, stage 2 is skipped.

import { spawnSync } from "child_process";
import { fileURLToPath } from "url";
import { dirname, resolve } from "path";

const here = dirname(fileURLToPath(import.meta.url));

const stages: { label: string; script: string }[] = [
  { label: "consolidated", script: "cloud-data-config-consolidated.ts" },
  { label: "derive",       script: "cloud-data-config-derive.ts" },
];

for (const { label, script } of stages) {
  const path = resolve(here, script);
  console.log(`\n=== cloud-data-config: stage '${label}' → ${script} ===`);
  const r = spawnSync("tsx", [path], { stdio: "inherit" });
  if (r.status !== 0) {
    console.error(`cloud-data-config: stage '${label}' failed (exit ${r.status ?? "signal"}); aborting.`);
    process.exit(r.status ?? 1);
  }
}

console.log("\ncloud-data-config: all stages complete.");
