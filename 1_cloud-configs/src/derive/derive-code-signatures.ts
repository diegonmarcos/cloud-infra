/**
 * derive-code-signatures.ts — deterministic code-signature extractor.
 *
 * Walks a repo's source and emits a per-file structural summary (NOT bodies):
 *   { path, lang, role, exports[], imports[], symbols[] }
 *
 * This is the reproducible "structure" layer that feeds BOTH:
 *   • the deterministic kg-graph (file/symbol/import nodes + edges), and
 *   • the Opus semantic pass (reads signatures, not full bodies → fits a token
 *     budget; full cloud source is ~5.6M tokens, signatures are ~10-15× smaller).
 *
 * Regex-based (no AST/toolchain dep). The extension → extractor map and the repo
 * list are DATA: the `code-signatures` entry of src/derivers.json (`languages`,
 * `repos`). Same input → byte-identical output (deterministic; no timestamps).
 *
 * Usage:  tsx derive-code-signatures.ts                               every declared repo → dist/code-signatures-<name>.json
 *         tsx derive-code-signatures.ts <repoRoot> <repoName> [outFile]  one repo
 * CODE_SIGNATURES_OUT_DIR overrides dist/ for the declared-repo mode.
 */
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, mkdirSync } from "fs";
import { join, relative, extname, dirname, resolve } from "path";

const SKIP_DIR = new Set(["node_modules", ".git", "dist", "z_archive", "z-archive", ".wrangler", "result", ".cargo-home", "target", ".terraform"]);
const SKIP_SUFFIX = [".lock", ".min.js", "-lock.json", ".map"];
const SKIP_SUBMODULE = ["cloud"];
const MAX_FILE = 400_000; // skip giant generated blobs

interface RepoDeclaration { name: string; root: string; skip_dirs?: string[] }
interface Declaration { repos: RepoDeclaration[]; languages: Record<string, string> }

const DERIVERS_JSON = join(import.meta.dirname!, "..", "derivers.json");
function loadDeclaration(path = DERIVERS_JSON): Declaration {
  const entry = JSON.parse(readFileSync(path, "utf-8")).derivers?.find((d: { name: string }) => d.name === "code-signatures");
  if (!entry?.repos?.length || !entry?.languages) throw new Error(`${path}: code-signatures entry must declare non-empty 'repos' and 'languages'`);
  return entry as Declaration;
}

interface FileSig {
  path: string; lang: string; role: string;
  exports: string[]; imports: string[]; symbols: string[];
}

function roleOf(path: string): string {
  const p = path.toLowerCase();
  if (p.endsWith("build.json")) return "service-config";
  if (p.endsWith("compose.nix")) return "compose";
  if (p.endsWith("flake.nix")) return "flake";
  if (p.includes("/engines/")) return "engine";
  if (p.includes("/scripts/")) return "script";
  if (p.includes("/hooks/")) return "hook";
  if (p.includes("/tools/") && p.endsWith(".ts")) return "mcp-tool";
  if (p.includes("/code/") && (p.endsWith("index.ts") || p.endsWith("main.ts") || p.endsWith("main.rs") || p.endsWith("main.py"))) return "entrypoint";
  if (p.includes("/dags/")) return "workflow-dag";
  if (p.endsWith(".nix")) return "nix-module";
  if (p.endsWith(".ts") || p.endsWith(".js")) return "module";
  if (p.endsWith(".rs")) return "rust-module";
  if (p.endsWith(".sh")) return "shell";
  if (p.endsWith(".py")) return "python";
  if (p.endsWith(".kt") || p.endsWith(".kts")) return "kotlin";
  if (p.endsWith(".java")) return "java";
  return "file";
}

const uniq = (a: string[]): string[] => [...new Set(a)].filter(Boolean);
const matchAll = (s: string, re: RegExp): string[] => {
  const g = re.global ? re : new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
  return [...s.matchAll(g)].map((m) => m[1]?.trim()).filter(Boolean) as string[];
};
const oneLine = (s: string): string => s.replace(/\s+/g, " ");

function extractTs(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const exports = uniq([
    ...matchAll(src, /export\s+(?:async\s+)?function\s+([A-Za-z0-9_]+)/g),
    ...matchAll(src, /export\s+(?:const|let|class|interface|type|enum)\s+([A-Za-z0-9_]+)/g),
    ...matchAll(src, /export\s*\{([^}]+)\}/g).flatMap((g) => g.split(",").map((x) => x.split(/\s+as\s+/)[0].trim())),
    ...(src.includes("export default") ? ["default"] : []),
  ]);
  const imports = uniq(matchAll(src, /import\s+(?:[^'"]+\s+from\s+)?['"]([^'"]+)['"]/g)
    .concat(matchAll(src, /require\(\s*['"]([^'"]+)['"]\s*\)/g)));
  const symbols = uniq([
    ...matchAll(src, /(?:export\s+)?(?:async\s+)?function\s+([A-Za-z0-9_]+\s*\([^)]*\))/g),
    ...matchAll(src, /(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z0-9_]+)/g).map((c) => `class ${c}`),
  ]).slice(0, 40);
  return { exports: exports.slice(0, 30), imports: imports.slice(0, 40), symbols };
}

function extractNix(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const imports = uniq(matchAll(src, /import\s+(\.\.?\/[^\s;]+)/g).concat(matchAll(src, /\.\/([A-Za-z0-9_./-]+\.nix)/g)));
  const symbols = uniq(matchAll(src, /^\s*([A-Za-z0-9_-]+)\s*=/gm)).slice(0, 40);
  const args = matchAll(src, /^\{([^}]*)\}:/m).flatMap((g) => g.split(",").map((x) => x.trim().split(/[?\s]/)[0]));
  return { exports: uniq(args).slice(0, 20), imports: imports.slice(0, 30), symbols };
}

function extractSh(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const symbols = uniq(matchAll(src, /^\s*(?:function\s+)?([A-Za-z0-9_]+)\s*\(\)\s*\{/gm)).map((f) => `${f}()`).slice(0, 40);
  const imports = uniq(matchAll(src, /(?:source|\.)\s+["']?([^\s"';]+\.sh)/g)).slice(0, 20);
  return { exports: symbols.slice(0, 30), imports, symbols };
}

function extractRust(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const exports = uniq([
    ...matchAll(src, /pub\s+(?:async\s+)?fn\s+([A-Za-z0-9_]+)/g),
    ...matchAll(src, /pub\s+(?:struct|enum|trait)\s+([A-Za-z0-9_]+)/g),
  ]);
  const imports = uniq(matchAll(src, /use\s+([A-Za-z0-9_:]+)/g)).slice(0, 40);
  const symbols = uniq(matchAll(src, /(?:pub\s+)?(?:async\s+)?fn\s+([A-Za-z0-9_]+\s*\([^)]*\))/g)).slice(0, 40);
  return { exports: exports.slice(0, 30), imports, symbols };
}

function extractPy(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const symbols = uniq([
    ...matchAll(src, /^def\s+([A-Za-z0-9_]+\s*\([^)]*\))/gm),
    ...matchAll(src, /^class\s+([A-Za-z0-9_]+)/gm).map((c) => `class ${c}`),
  ]).slice(0, 40);
  const imports = uniq(matchAll(src, /^(?:from\s+([A-Za-z0-9_.]+)\s+import|import\s+([A-Za-z0-9_.]+))/gm)
    .concat(matchAll(src, /^import\s+([A-Za-z0-9_.]+)/gm))).slice(0, 30);
  return { exports: symbols.filter((s) => !s.startsWith("_")).slice(0, 30), imports, symbols };
}

// Kotlin: declarations are public unless marked private/internal, so a top-level
// (column 0) declaration without those modifiers is an export.
function extractKotlin(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const imports = uniq(matchAll(src, /^import\s+([A-Za-z0-9_.*]+)/gm)).slice(0, 40);
  const exports = uniq(matchAll(src,
    /^(?:(?:public|open|abstract|sealed|data|enum|annotation|inline|value|suspend|operator|infix|tailrec|actual|expect|const|fun)\s+)*(?:fun\s+(?:<[^>\n]*>\s*)?(?:[A-Za-z0-9_.]+\.)?|class\s+|interface\s+|object\s+|val\s+|var\s+|typealias\s+)([A-Za-z0-9_]+)/gm));
  const symbols = uniq([
    ...matchAll(src, /\bfun\s+(?:<[^>\n]*>\s*)?(?:[A-Za-z0-9_.]+\.)?([A-Za-z0-9_]+\s*\([^)]*\))/g).map(oneLine),
    ...matchAll(src, /\b(?:class|interface|object)\s+([A-Za-z0-9_]+)/g).map((c) => `class ${c}`),
  ]).slice(0, 40);
  return { exports: exports.slice(0, 30), imports, symbols };
}

const JAVA_NOT_METHOD = new Set(["if", "for", "while", "switch", "catch", "synchronized", "return", "new", "else"]);
function extractJava(src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  const imports = uniq(matchAll(src, /^import\s+(?:static\s+)?([A-Za-z0-9_.*]+)\s*;/gm)).slice(0, 40);
  const methods = matchAll(src, /^[ \t]*(?:(?:public|protected|private|static|final|abstract|synchronized|native|default)[ \t]+)*[A-Za-z0-9_.?[\]]+(?:<[^>\n]*>)?[ \t]+([A-Za-z0-9_]+[ \t]*\([^)]*\))[ \t\n]*(?:throws[^{;]*)?\{/gm)
    .map(oneLine).filter((m) => !JAVA_NOT_METHOD.has(m.replace(/\s*\(.*$/, "")));
  const exports = uniq([
    ...matchAll(src, /\bpublic\s+(?:(?:static|final|abstract|sealed)\s+)*(?:class|interface|enum|record)\s+([A-Za-z0-9_]+)/g),
    ...matchAll(src, /\bpublic\s+(?:(?:static|final|abstract|synchronized|native|default)\s+)*[A-Za-z0-9_.?[\]]+(?:<[^>\n]*>)?\s+([A-Za-z0-9_]+)\s*\(/g),
  ]);
  const symbols = uniq([
    ...methods,
    ...matchAll(src, /\b(?:class|interface|enum|record)\s+([A-Za-z0-9_]+)/g).map((c) => `class ${c}`),
  ]).slice(0, 40);
  return { exports: exports.slice(0, 30), imports, symbols };
}

function extract(lang: string, src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  switch (lang) {
    case "ts": case "js": return extractTs(src);
    case "nix": return extractNix(src);
    case "sh": return extractSh(src);
    case "rust": return extractRust(src);
    case "py": return extractPy(src);
    case "kotlin": return extractKotlin(src);
    case "java": return extractJava(src);
    default: throw new Error(`derivers.json code-signatures.languages names '${lang}', which has no extractor`);
  }
}

function walk(root: string, dir: string, out: FileSig[], languages: Record<string, string>, skipDirs: Set<string>): void {
  let entries: string[];
  try { entries = readdirSync(dir).sort(); } catch { return; }
  for (const name of entries) {
    if (SKIP_DIR.has(name) || skipDirs.has(name)) continue;
    const full = join(dir, name);
    let st;
    try { st = statSync(full); } catch { continue; }
    const rel = relative(root, full);
    const relLow = rel.toLowerCase();
    if (SKIP_SUBMODULE.some((s) => relLow === s || relLow.startsWith(s + "/"))) continue;
    if (st.isDirectory()) { walk(root, full, out, languages, skipDirs); continue; }
    if (!st.isFile() || st.size > MAX_FILE) continue;
    if (SKIP_SUFFIX.some((s) => relLow.endsWith(s))) continue;
    const lang = languages[extname(name).toLowerCase()];
    if (!lang) continue;
    let src: string;
    try { src = readFileSync(full, "utf-8"); } catch { continue; }
    const { exports, imports, symbols } = extract(lang, src);
    if (!exports.length && !imports.length && !symbols.length) continue; // skip empty
    out.push({ path: rel, lang, role: roleOf(rel), exports, imports, symbols });
  }
}

function deriveRepo(root: string, repo: string, outFile: string, languages: Record<string, string>, skipDirs: string[] = []): void {
  const out: FileSig[] = [];
  walk(root, root, out, languages, new Set(skipDirs));
  out.sort((a, b) => a.path.localeCompare(b.path));
  const data = {
    _warning: "AUTO-GENERATED — deterministic signature extract. Regenerate: tsx 1_cloud-configs/src/derive/derive-code-signatures.ts",
    _meta: { description: `Per-file code signatures for repo '${repo}' — structure only (exports/imports/symbols), no bodies.`, format_version: 1 },
    repo,
    counts: {
      files: out.length,
      by_lang: out.reduce((a: Record<string, number>, f) => ((a[f.lang] = (a[f.lang] ?? 0) + 1), a), {}),
      by_role: out.reduce((a: Record<string, number>, f) => ((a[f.role] = (a[f.role] ?? 0) + 1), a), {}),
    },
    files: out,
  };
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, JSON.stringify(data, null, 2));
  const bytes = statSync(outFile).size;
  console.error(`derive-code-signatures: ${repo}: ${out.length} files → ${outFile} (${(bytes / 1024).toFixed(0)}KB, ~${Math.round(bytes / 4 / 1000)}k tokens)`);
}

function main(): void {
  const { repos, languages } = loadDeclaration();
  const CLOUD_ROOT = process.env.CLOUD_ROOT ?? join(import.meta.dirname!, "..", "..", "..");
  const DIST = join(import.meta.dirname!, "..", "..", "dist");
  if (process.argv[2]) {
    const repo = process.argv[3] ?? "cloud";
    deriveRepo(process.argv[2], repo, process.argv[4] ?? join(DIST, `code-signatures-${repo}.json`), languages);
    return;
  }
  const outDir = process.env.CODE_SIGNATURES_OUT_DIR ?? DIST;
  for (const r of repos) {
    const root = resolve(CLOUD_ROOT, r.root);
    if (!existsSync(root)) {
      // Not fatal: a checkout that lacks a sibling repository must not break every other deriver.
      // derive-code-signatures.test.ts reports the declared repository as missing instead.
      console.error(`::warning::derive-code-signatures: declared repo '${r.name}' root ${root} is not checked out — its signatures were NOT refreshed`);
      continue;
    }
    deriveRepo(root, r.name, join(outDir, `code-signatures-${r.name}.json`), languages, r.skip_dirs);
  }
}

main();
