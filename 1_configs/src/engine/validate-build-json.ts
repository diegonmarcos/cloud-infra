// validate-build-json.ts — Enforce:
//   A) No two containers share a container_name across build.json files
//   B) Every declared port has an explicit `protocol` ∈ {http,https,tls,starttls,tcp,udp}
//      - containers.<x>.port → requires sibling containers.<x>.protocol
//      - containers.<x>.extra_ports[] → each element must be {port, protocol}
//      - proxy.primary.l4_ports[] → requires `protocol` on each entry
//
// READ-ONLY. Exits non-zero on any violation.
//
// Run: npx tsx validate-build-json.ts

import { readFileSync, readdirSync, statSync } from "fs";
import { resolve, join } from "path";

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT = resolve(ENGINE_DIR, "../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT, "..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");

const PROTOCOL_ENUM = new Set(["http", "https", "tls", "starttls", "tcp", "udp"]);

interface Ref {
  service: string;
  container_key: string;
  file: string;
}
interface Violation {
  kind: "DUPLICATE_CONTAINER_NAME" | "MISSING_PROTOCOL" | "INVALID_PROTOCOL" | "EXTRA_PORT_NOT_OBJECT";
  service: string;
  file: string;
  detail: string;
}

const byName = new Map<string, Ref[]>();
const violations: Violation[] = [];

for (const d of readdirSync(SOLUTIONS_DIR).sort()) {
  const p = join(SOLUTIONS_DIR, d);
  try { if (!statSync(p).isDirectory()) continue; } catch { continue; }
  const bjPath = join(p, "build.json");
  let bj: any;
  try { bj = JSON.parse(readFileSync(bjPath, "utf-8")); } catch { continue; }
  const service = bj.name ?? d;
  const containers = bj.containers ?? {};

  if (Object.keys(containers).length === 0) {
    const list = byName.get(service) ?? [];
    list.push({ service, container_key: "(implicit)", file: bjPath });
    byName.set(service, list);
    continue;
  }

  for (const [ck, c] of Object.entries(containers) as [string, any][]) {
    // A: duplicate container_name
    if (c.container_name) {
      const list = byName.get(c.container_name) ?? [];
      list.push({ service, container_key: ck, file: bjPath });
      byName.set(c.container_name, list);
    }

    // B.1: primary port requires protocol
    if (typeof c.port === "number") {
      if (!c.protocol) {
        violations.push({ kind: "MISSING_PROTOCOL", service, file: bjPath, detail: `containers.${ck}.port=${c.port} has no sibling protocol` });
      } else if (!PROTOCOL_ENUM.has(c.protocol)) {
        violations.push({ kind: "INVALID_PROTOCOL", service, file: bjPath, detail: `containers.${ck}.protocol="${c.protocol}" is not in enum` });
      }
    }

    // B.2: extra_ports must be {port, protocol} objects
    if (Array.isArray(c.extra_ports)) {
      for (let i = 0; i < c.extra_ports.length; i++) {
        const ep = c.extra_ports[i];
        if (typeof ep === "number") {
          violations.push({ kind: "EXTRA_PORT_NOT_OBJECT", service, file: bjPath, detail: `containers.${ck}.extra_ports[${i}]=${ep} is a number — should be {port, protocol}` });
          continue;
        }
        if (typeof ep !== "object" || typeof ep.port !== "number") {
          violations.push({ kind: "EXTRA_PORT_NOT_OBJECT", service, file: bjPath, detail: `containers.${ck}.extra_ports[${i}] invalid shape` });
          continue;
        }
        if (!ep.protocol) {
          violations.push({ kind: "MISSING_PROTOCOL", service, file: bjPath, detail: `containers.${ck}.extra_ports[${i}] port=${ep.port} has no protocol` });
        } else if (!PROTOCOL_ENUM.has(ep.protocol)) {
          violations.push({ kind: "INVALID_PROTOCOL", service, file: bjPath, detail: `containers.${ck}.extra_ports[${i}].protocol="${ep.protocol}" not in enum` });
        }
      }
    }
  }

  // B.3: l4_ports require protocol
  const l4 = bj.proxy?.primary?.l4_ports ?? [];
  for (let i = 0; i < l4.length; i++) {
    const entry = l4[i];
    if (typeof entry !== "object") continue;
    if (!entry.protocol) {
      violations.push({ kind: "MISSING_PROTOCOL", service, file: bjPath, detail: `proxy.primary.l4_ports[${i}] port=${entry.port} has no protocol` });
    } else if (!PROTOCOL_ENUM.has(entry.protocol)) {
      violations.push({ kind: "INVALID_PROTOCOL", service, file: bjPath, detail: `proxy.primary.l4_ports[${i}].protocol="${entry.protocol}" not in enum` });
    }
  }
}

// Duplicate container_name check
const dupes = [...byName.entries()].filter(([, refs]) => refs.length > 1);
for (const [name, refs] of dupes) {
  violations.push({
    kind: "DUPLICATE_CONTAINER_NAME",
    service: refs.map(r => r.service).join(" + "),
    file: refs.map(r => r.file).join(", "),
    detail: `container_name "${name}" appears ${refs.length}× (services: ${[...new Set(refs.map(r => r.service))].join(", ")})`,
  });
}

// Report
console.log(`Scanned ${byName.size} container names across ${readdirSync(SOLUTIONS_DIR).length} service dirs.\n`);

if (violations.length === 0) {
  console.log("✓ All checks passed.");
  console.log("  ✓ No duplicate container_name");
  console.log("  ✓ All ports have valid protocol");
  process.exit(0);
}

const byKind: Record<string, Violation[]> = {};
for (const v of violations) (byKind[v.kind] ??= []).push(v);

for (const [kind, list] of Object.entries(byKind)) {
  console.log(`✗ ${kind} (${list.length})`);
  for (const v of list) {
    console.log(`  [${v.service}] ${v.detail}`);
    console.log(`    ${v.file}`);
  }
  console.log();
}
console.log(`Total violations: ${violations.length}`);
process.exit(1);
