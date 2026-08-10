// validate-build-schema.ts — Validate the `api` and `mcp` blocks of every
// a_solutions/<svc>/build.json against build.schema.json's sub-schemas.
//
// Scope: deliberately narrow. The full schema is out of sync with several
// historical fields (headers_enforced, arch, native_build, primary, etc.);
// reconciling that is a separate concern. This validator enforces only the
// new declarative surfaces (`api`, `mcp`) so we can guarantee the registry
// derive engine receives well-formed declarations.
//
// Invocation:
//   npx tsx 1_configs/src/engines/validate-build-schema.ts
//
// CI gate via 1_configs/src/test/test_build_schema_api_mcp.sh.

import { readFileSync, readdirSync, statSync } from "fs";
import { resolve, join } from "path";
import Ajv from "ajv";
import addFormats from "ajv-formats";

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT = resolve(ENGINE_DIR, "../../..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const SCHEMA_PATH = join(SOLUTIONS_DIR, "build.schema.json");

const fullSchema = JSON.parse(readFileSync(SCHEMA_PATH, "utf-8"));
const apiSchema = fullSchema.properties?.api;
const mcpSchema = fullSchema.properties?.mcp;
if (!apiSchema || !mcpSchema) {
  console.error("FATAL: build.schema.json missing api or mcp block.");
  process.exit(2);
}

const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);
const validateApi = ajv.compile(apiSchema);
const validateMcp = ajv.compile(mcpSchema);

let total = 0;
let withApi = 0;
let withMcp = 0;
let failed = 0;
const failures: { service: string; field: "api" | "mcp"; errors: string[] }[] = [];

for (const d of readdirSync(SOLUTIONS_DIR).sort()) {
  const p = join(SOLUTIONS_DIR, d);
  try { if (!statSync(p).isDirectory()) continue; } catch { continue; }
  const bjPath = join(p, "build.json");
  let bj: any;
  try { bj = JSON.parse(readFileSync(bjPath, "utf-8")); } catch { continue; }
  total++;

  if (bj.api !== undefined) {
    withApi++;
    if (!validateApi(bj.api)) {
      failed++;
      failures.push({
        service: d,
        field: "api",
        errors: (validateApi.errors ?? []).map(
          (e) => `${e.instancePath || "(root)"} ${e.message ?? ""} ${e.params ? JSON.stringify(e.params) : ""}`,
        ),
      });
    }
  }

  if (bj.mcp !== undefined) {
    withMcp++;
    if (!validateMcp(bj.mcp)) {
      failed++;
      failures.push({
        service: d,
        field: "mcp",
        errors: (validateMcp.errors ?? []).map(
          (e) => `${e.instancePath || "(root)"} ${e.message ?? ""} ${e.params ? JSON.stringify(e.params) : ""}`,
        ),
      });
    }
  }
}

console.log(`Scanned ${total} build.json — ${withApi} with api, ${withMcp} with mcp.`);
if (failed === 0) {
  console.log(`✓ All ${withApi + withMcp} api/mcp blocks valid.`);
  process.exit(0);
}

console.log(`✗ ${failed} block(s) failed validation:\n`);
for (const f of failures) {
  console.log(`  [${f.service}] ${f.field}:`);
  for (const e of f.errors) console.log(`    ${e}`);
}
process.exit(1);
