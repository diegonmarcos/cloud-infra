// apply-api-mcp-blocks.ts — Inject the declarative `api` / `mcp` blocks into every build.json.
//
// Reads: declarations file (default: ~/.claude/plans/c3-services-api-declarations.json)
//        — but accepts --decls=<path> to override. The file is NOT in the repo because
//        once applied, each service's build.json is the source of truth.
//
// Writes: a_solutions/<folder>/build.json (in-place, idempotent, deep-merge into the api/mcp keys).
//
// For each entry under .apis[<folder>] → write build.json.api = <entry>
// For each entry under .mcps[<folder>] → write build.json.mcp = <entry>
//
// Skips writes when the existing block is already deep-equal.
// Pretty-prints with 2-space indent + trailing newline.
//
// Run: npx tsx apply-api-mcp-blocks.ts                          (write)
//      npx tsx apply-api-mcp-blocks.ts --dry                    (preview diff only)
//      npx tsx apply-api-mcp-blocks.ts --decls=/path/to/x.json  (override declarations file)

import { readFileSync, writeFileSync, existsSync } from "fs";
import { resolve, join } from "path";
import { homedir } from "os";

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT = resolve(ENGINE_DIR, "../../..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");

const dry = process.argv.includes("--dry");
const declsArg = process.argv.find((a) => a.startsWith("--decls="))?.slice("--decls=".length);
const DECLS_PATH = declsArg ?? join(homedir(), ".claude/plans/c3-services-api-declarations.json");

if (!existsSync(DECLS_PATH)) {
  console.error(`FATAL: declarations file not found at ${DECLS_PATH}`);
  process.exit(1);
}

interface Declarations {
  apis: Record<string, Record<string, unknown>>;
  mcps: Record<string, Record<string, unknown>>;
}
const decls = JSON.parse(readFileSync(DECLS_PATH, "utf-8")) as Declarations;

function deepEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function applyBlock(folder: string, block: "api" | "mcp", payload: Record<string, unknown>): "wrote" | "noop" | "skip" {
  const bjPath = join(SOLUTIONS_DIR, folder, "build.json");
  if (!existsSync(bjPath)) {
    console.error(`  [${folder}] build.json missing — SKIP`);
    return "skip";
  }
  const before = readFileSync(bjPath, "utf-8");
  const bj = JSON.parse(before);
  if (deepEqual(bj[block], payload)) return "noop";
  bj[block] = payload;
  const after = JSON.stringify(bj, null, 2) + "\n";
  if (dry) {
    console.log(`  [${folder}] would write ${block} block`);
    return "wrote";
  }
  writeFileSync(bjPath, after);
  console.log(`  [${folder}] ${block} block ${bj[block] ? "set" : "removed"}`);
  return "wrote";
}

console.log(`apply-api-mcp-blocks: reading ${DECLS_PATH}${dry ? " (dry-run)" : ""}\n`);

let wrote = 0; let noop = 0; let skip = 0;

console.log("── api blocks ──");
for (const [folder, payload] of Object.entries(decls.apis ?? {})) {
  const r = applyBlock(folder, "api", payload);
  if (r === "wrote") wrote++; else if (r === "noop") noop++; else skip++;
}

console.log("\n── mcp blocks ──");
for (const [folder, payload] of Object.entries(decls.mcps ?? {})) {
  const r = applyBlock(folder, "mcp", payload);
  if (r === "wrote") wrote++; else if (r === "noop") noop++; else skip++;
}

console.log(`\nDone. wrote=${wrote} noop=${noop} skip=${skip}`);
process.exit(0);
