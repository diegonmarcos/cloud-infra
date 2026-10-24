// derive-containers-declared.mjs - THIN WRAPPER (#1148). The derivation of dist/containers-declared.json
// is NOT here: its canonical home is the configs-sync engine, cloud-u-containers
// infra-obs_configs-sync/src/code/containers-declared.mjs. This wrapper only runs it so the output keeps
// being produced in this repo's dist/ until the engine is live and publishes to the data repo
// (cloud_db_infra-ops-obsv_configs-sync). No second implementation, no second source of truth.
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const cloudRoot = process.env.CLOUD_ROOT || path.resolve(here, "../../..");
const solutions = path.join(cloudRoot, "a_solutions");
const engine = path.join(solutions, "infra-obs_configs-sync/src/code/containers-declared.mjs");
if (!fs.existsSync(engine)) { console.error("derive-containers-declared: engine missing at " + engine); process.exit(1); }
const { derive } = await import(pathToFileURL(engine).href);
const out = path.join(here, "../../dist/containers-declared.json");
fs.writeFileSync(out, JSON.stringify(derive(solutions), null, 2) + "\n");
console.log("wrote " + out);
