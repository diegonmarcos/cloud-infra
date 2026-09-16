/**
 * derive-code-signatures.test.ts — stops the code index going blind to a language silently.
 *
 * RED when, for any repo declared in derivers.json code-signatures.repos:
 *   1. the repo is not checked out, so nothing below can be verified for it;
 *   2. a declared language (derivers.json code-signatures.languages) has tracked files in the repo
 *      but the PINNED octocode indexer does not select that extension. Accepted set = the pinned
 *      release's own src/indexer/file_utils.rs (detect_language arms + ALLOWED_TEXT_EXTENSIONS),
 *      plus build.json .runtime.octocode.file_associations — counted only when EVERY script that
 *      writes config.toml actually consumes that key, so a declaration nobody applies is not green.
 *      There are TWO such writers and both are required: cloud-cgc-db-update.sh (the CI producer)
 *      and user-ai_cloud-cgc-pub-mcp/src/code/reindex.sh (the one-shot reindex/index jobs, and the
 *      box-side tail cloud-cgc-db-restore-all.sh execs inside the MCP container). Checking only the
 *      first is how kt/kts stayed declared-but-unapplied on the serving boxes while this test was
 *      green: CI built a Kotlin-aware index, then an on-box reindex rebuilt a Kotlin-blind one over it;
 *   3. the bundled codegraph source code-signatures-<name>.json is missing, carries another repo
 *      name, or holds zero files for a declared language the repo contains (the green-looking no-op).
 *
 * Usage: node derive-code-signatures.test.ts
 * Overrides (for fixtures): CLOUD_ROOT, DERIVERS_JSON, CGC_BUILD_JSON, CGC_DB_UPDATE_SH,
 *   OCTOCODE_FILE_UTILS_RS (local file instead of fetching the pinned release source), CODEGRAPH_GRAPHS_DIR.
 */
import { readFileSync, existsSync } from "fs";
import { join, resolve, extname } from "path";
import { execFileSync } from "child_process";

const CLOUD_ROOT = process.env.CLOUD_ROOT ?? join(import.meta.dirname!, "..", "..", "..");
const firstExisting = (...paths: string[]): string => paths.find((p) => existsSync(p)) ?? paths[0];
// CI checks cloud-u-containers out as cloud-infra/a_solutions; a workstation has it as a sibling.
const PUB_MCP = firstExisting(join(CLOUD_ROOT, "a_solutions", "user-ai_cloud-cgc-pub-mcp"), join(CLOUD_ROOT, "..", "cloud-u-containers", "user-ai_cloud-cgc-pub-mcp"));
const DERIVERS_JSON = process.env.DERIVERS_JSON ?? join(import.meta.dirname!, "..", "derivers.json");
const BUILD_JSON = process.env.CGC_BUILD_JSON ?? join(PUB_MCP, "build.json");
const UPDATE_SH = process.env.CGC_DB_UPDATE_SH ?? join(CLOUD_ROOT, "1_cicd", "src", "ops", "cloud-cgc-db-update.sh");
const REINDEX_SH = process.env.CGC_REINDEX_SH ?? join(PUB_MCP, "src", "code", "reindex.sh");
const GRAPHS_DIR = process.env.CODEGRAPH_GRAPHS_DIR ?? join(PUB_MCP, "src", "code", "graphs");

let failures = 0;
const ok = (msg: string): void => console.log(`  ok   ${msg}`);
const fail = (msg: string): void => { failures++; console.log(`  FAIL ${msg}`); };

async function octocodeAcceptedExtensions(version: string): Promise<{ extensions: Set<string>; grammars: Set<string> }> {
  let rs: string;
  if (process.env.OCTOCODE_FILE_UTILS_RS) rs = readFileSync(process.env.OCTOCODE_FILE_UTILS_RS, "utf-8");
  else {
    const url = `https://raw.githubusercontent.com/Muvon/octocode/${version}/src/indexer/file_utils.rs`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
    rs = await response.text();
  }
  const detect = rs.match(/pub fn detect_language[\s\S]*?match path\.extension\(\)[\s\S]*?\{([\s\S]*?)_ => None/);
  const text = rs.match(/ALLOWED_TEXT_EXTENSIONS: &\[&str\] = &\[([\s\S]*?)\];/);
  if (!detect || !text) throw new Error("octocode file_utils.rs no longer has the detect_language / ALLOWED_TEXT_EXTENSIONS shape this tester parses — re-read the pinned source");
  const extensions = new Set<string>();
  const grammars = new Set<string>();
  for (const arm of detect[1].matchAll(/((?:"[^"]+"\s*\|?\s*)+)=>\s*Some\("([^"]+)"\)/g)) {
    for (const e of arm[1].matchAll(/"([^"]+)"/g)) extensions.add(e[1]);
    grammars.add(arm[2]);
  }
  for (const e of text[1].matchAll(/"([^"]+)"/g)) extensions.add(e[1]);
  return { extensions, grammars };
}

function trackedExtensionCounts(root: string): Map<string, number> {
  const counts = new Map<string, number>();
  const files = execFileSync("git", ["-C", root, "ls-files", "-z"], { maxBuffer: 1 << 28 }).toString().split("\0");
  for (const f of files) { const e = extname(f).toLowerCase(); if (e) counts.set(e, (counts.get(e) ?? 0) + 1); }
  return counts;
}

async function main(): Promise<void> {
  const entry = JSON.parse(readFileSync(DERIVERS_JSON, "utf-8")).derivers?.find((d: { name: string }) => d.name === "code-signatures");
  const repos: Array<{ name: string; root: string }> = entry?.repos ?? [];
  const languages: Record<string, string> = entry?.languages ?? {};
  if (!repos.length) fail(`${DERIVERS_JSON}: code-signatures declares no repos`);
  if (!Object.keys(languages).length) fail(`${DERIVERS_JSON}: code-signatures declares no languages`);

  const octocode = JSON.parse(readFileSync(BUILD_JSON, "utf-8")).runtime?.octocode ?? {};
  const { extensions, grammars } = await octocodeAcceptedExtensions(octocode.version);
  const associations: Record<string, string> = octocode.file_associations ?? {};
  // EVERY config.toml writer must apply the key, not just the CI producer — an
  // association the on-box reindex path ignores is undone the next time that path runs.
  const writers = [UPDATE_SH, REINDEX_SH];
  const unapplied = writers.filter((p) => !existsSync(p) || !readFileSync(p, "utf-8").includes("file_associations"));
  for (const [e, grammar] of Object.entries(associations)) {
    if (!grammars.has(grammar)) fail(`build.json file_associations ${e} = "${grammar}": octocode ${octocode.version} has no such grammar`);
    else if (unapplied.length) fail(`build.json file_associations ${e} = "${grammar}" is declared but never applied to config.toml by: ${unapplied.join(", ")}`);
    else extensions.add(e.replace(/^\./, ""));
  }
  console.log(`octocode ${octocode.version}: ${extensions.size} accepted extensions`);

  for (const r of repos) {
    const root = resolve(CLOUD_ROOT, r.root);
    console.log(`repo ${r.name} (${root})`);
    if (!existsSync(join(root, ".git"))) { fail(`${r.name}: declared root is not a checked-out git repository`); continue; }
    const counts = trackedExtensionCounts(root);
    const present = Object.keys(languages).filter((e) => (counts.get(e) ?? 0) > 0);
    for (const e of present) {
      if (extensions.has(e.slice(1))) ok(`${r.name}: indexer accepts ${e} (${counts.get(e)} files)`);
      else fail(`${r.name}: ${counts.get(e)} tracked ${e} files are invisible to octocode ${octocode.version}`);
    }
    const bundle = join(GRAPHS_DIR, `code-signatures-${r.name}.json`);
    if (!existsSync(bundle)) { fail(`${r.name}: codegraph source ${bundle} missing`); continue; }
    const sig = JSON.parse(readFileSync(bundle, "utf-8"));
    if (sig.repo !== r.name) fail(`${r.name}: ${bundle} carries repo '${sig.repo}'`);
    const byLang: Record<string, number> = sig.counts?.by_lang ?? {};
    for (const lang of new Set(present.map((e) => languages[e]))) {
      if ((byLang[lang] ?? 0) > 0) ok(`${r.name}: codegraph source has ${byLang[lang]} ${lang} files`);
      else fail(`${r.name}: codegraph source has 0 ${lang} files although the repo tracks ${present.filter((e) => languages[e] === lang).join("/")}`);
    }
  }
  console.log(failures ? `RED: ${failures} failure(s)` : "GREEN");
  process.exit(failures ? 1 : 0);
}

await main();
