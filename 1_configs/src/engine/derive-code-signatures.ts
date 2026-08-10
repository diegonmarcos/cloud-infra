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
 * Regex-based (no AST/toolchain dep) — covers ts/tsx/js/mjs/nix/sh/bash/rs/py.
 * Same input → byte-identical output (deterministic; no timestamps unless the
 * caller stamps them).
 *
 * Usage:  tsx derive-code-signatures.ts <repoRoot> <repoName> [outFile]
 * Default (no args): cloud repo at CLOUD_ROOT → dist/code-signatures-cloud.json
 */
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, mkdirSync } from "fs";
import { join, relative, extname, dirname, basename } from "path";

const SKIP_DIR = new Set(["node_modules", ".git", "dist", "z_archive", "z-archive", ".wrangler", "result", ".cargo-home", "target", ".terraform"]);
const SKIP_SUFFIX = [".lock", ".min.js", "-lock.json", ".map"];
const SKIP_SUBMODULE = ["i_cloud-data", "iii_unix", "ii_tools", "iii_front-data"];
const LANG: Record<string, string> = {
  ".ts": "ts", ".tsx": "ts", ".mts": "ts", ".js": "js", ".mjs": "js", ".cjs": "js",
  ".nix": "nix", ".sh": "sh", ".bash": "sh", ".rs": "rust", ".py": "py",
};
const MAX_FILE = 400_000; // skip giant generated blobs

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
  return "file";
}

const uniq = (a: string[]): string[] => [...new Set(a)].filter(Boolean);
const matchAll = (s: string, re: RegExp): string[] => {
  const g = re.global ? re : new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
  return [...s.matchAll(g)].map((m) => m[1]?.trim()).filter(Boolean) as string[];
};

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

function extract(lang: string, src: string): Pick<FileSig, "exports" | "imports" | "symbols"> {
  switch (lang) {
    case "ts": case "js": return extractTs(src);
    case "nix": return extractNix(src);
    case "sh": return extractSh(src);
    case "rust": return extractRust(src);
    case "py": return extractPy(src);
    default: return { exports: [], imports: [], symbols: [] };
  }
}

function walk(root: string, dir: string, out: FileSig[]): void {
  let entries: string[];
  try { entries = readdirSync(dir); } catch { return; }
  for (const name of entries) {
    if (SKIP_DIR.has(name)) continue;
    const full = join(dir, name);
    let st;
    try { st = statSync(full); } catch { continue; }
    const rel = relative(root, full);
    const relLow = rel.toLowerCase();
    if (SKIP_SUBMODULE.some((s) => relLow.startsWith(s))) continue;
    if (st.isDirectory()) { walk(root, full, out); continue; }
    if (!st.isFile() || st.size > MAX_FILE) continue;
    if (SKIP_SUFFIX.some((s) => relLow.endsWith(s))) continue;
    const lang = LANG[extname(name).toLowerCase()];
    if (!lang) continue;
    let src: string;
    try { src = readFileSync(full, "utf-8"); } catch { continue; }
    const { exports, imports, symbols } = extract(lang, src);
    if (!exports.length && !imports.length && !symbols.length) continue; // skip empty
    out.push({ path: rel, lang, role: roleOf(rel), exports, imports, symbols });
  }
}

function main(): void {
  const CLOUD_ROOT = process.env.CLOUD_ROOT ?? join(import.meta.dirname!, "..", "..", "..");
  const root = process.argv[2] ?? CLOUD_ROOT;
  const repo = process.argv[3] ?? "cloud";
  const out: FileSig[] = [];
  walk(root, root, out);
  out.sort((a, b) => a.path.localeCompare(b.path));
  const data = {
    _warning: "AUTO-GENERATED — deterministic signature extract. Regenerate: tsx 1_configs/src/engine/derive-code-signatures.ts",
    _meta: { description: `Per-file code signatures for repo '${repo}' — structure only (exports/imports/symbols), no bodies.`, format_version: 1 },
    repo,
    counts: {
      files: out.length,
      by_lang: out.reduce((a: Record<string, number>, f) => ((a[f.lang] = (a[f.lang] ?? 0) + 1), a), {}),
      by_role: out.reduce((a: Record<string, number>, f) => ((a[f.role] = (a[f.role] ?? 0) + 1), a), {}),
    },
    files: out,
  };
  const outFile = process.argv[4] ?? join(import.meta.dirname!, "..", "..", "dist", `code-signatures-${repo}.json`);
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, JSON.stringify(data, null, 2));
  const bytes = statSync(outFile).size;
  console.error(`derive-code-signatures: ${out.length} files → ${outFile} (${(bytes / 1024).toFixed(0)}KB, ~${Math.round(bytes / 4 / 1000)}k tokens)`);
}

main();
