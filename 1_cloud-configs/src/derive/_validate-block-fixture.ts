// _validate-block-fixture.ts — Test helper for the schema-gate test.
//
// Validates a single JSON fixture against a sub-schema (api or mcp) of
// build.schema.json. Used by 9_others/test/test_build_schema_api_mcp.sh.
//
// Usage: npx tsx _validate-block-fixture.ts <schema-path> <fixture-path> <block>
//   exit 0 + "VALID"   on pass
//   exit 1 + "INVALID" on fail
//   exit 2 on usage error

import { readFileSync } from "fs";
import Ajv from "ajv";
import addFormats from "ajv-formats";

const [, , schemaPath, fixturePath, blockKey] = process.argv;
if (!schemaPath || !fixturePath || !blockKey) {
  console.error("usage: _validate-block-fixture.ts <schema> <fixture> <block>");
  process.exit(2);
}

const full = JSON.parse(readFileSync(schemaPath, "utf-8"));
delete full.$schema;
const sub = full.properties?.[blockKey];
if (!sub) {
  console.error(`schema has no block "${blockKey}"`);
  process.exit(2);
}
const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);
const v = ajv.compile(sub);
const data = JSON.parse(readFileSync(fixturePath, "utf-8"));
if (v(data)) {
  console.log("VALID");
  process.exit(0);
}
console.log("INVALID");
for (const e of v.errors ?? []) {
  console.log(`  ${e.instancePath || "(root)"} ${e.message ?? ""} ${JSON.stringify(e.params)}`);
}
process.exit(1);
