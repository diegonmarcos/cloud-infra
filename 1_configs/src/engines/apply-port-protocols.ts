// apply-port-protocols.ts — Apply the approved protocol draft back into every build.json.
//
// Reads: port-protocol-draft.json  (produced by draft-port-protocols.ts)
// Writes: a_solutions/*/build.json  (in-place, idempotent)
//
// For each port entry in the draft:
//   - location=primary → writes sibling `protocol` next to `port`
//   - location=extra   → converts extra_ports from number[] to PortSpec[] {port, protocol}
//   - location=l4      → writes `protocol` into the l4_ports[] entry
//
// Preserves JSON key order where possible. Pretty-prints with 2-space indent.
//
// Run: npx tsx apply-port-protocols.ts          (write)
//      npx tsx apply-port-protocols.ts --dry    (preview diff only)

import { readFileSync, writeFileSync } from "fs";
import { resolve, join } from "path";

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT = resolve(ENGINE_DIR, "../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT, "..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const DRAFT_FILE = join(ENGINE_DIR, "port-protocol-draft.json");

const dry = process.argv.includes("--dry");

type Protocol = "http" | "https" | "tls" | "starttls" | "tcp" | "udp";
const ENUM: readonly Protocol[] = ["http", "https", "tls", "starttls", "tcp", "udp"];

interface DraftPort {
  location: "primary" | "extra" | "l4";
  location_path: string;
  port: number;
  protocol: Protocol;
}
interface DraftContainer {
  container_key: string;
  container_name: string;
  ports: DraftPort[];
}
interface DraftService {
  service: string;
  folder: string;
  containers: DraftContainer[];
}
interface Draft {
  services: DraftService[];
}

function applyToBuildJson(bj: any, svc: DraftService): { changed: boolean; writes: string[] } {
  const writes: string[] = [];
  const containers = bj.containers ?? {};

  for (const dc of svc.containers) {
    const c = containers[dc.container_key];
    if (!c) continue;

    // Build a lookup: port → protocol from draft
    const primaryPort = dc.ports.find(p => p.location === "primary");
    const extraPorts = dc.ports.filter(p => p.location === "extra");
    const l4Ports = dc.ports.filter(p => p.location === "l4");

    // 1. Primary port → add sibling `protocol`
    if (primaryPort && typeof c.port === "number" && c.port === primaryPort.port) {
      if (c.protocol !== primaryPort.protocol) {
        c.protocol = primaryPort.protocol;
        writes.push(`containers.${dc.container_key}.protocol = "${primaryPort.protocol}"`);
      }
    }

    // 2. extra_ports: number[] → PortSpec[]
    if (extraPorts.length > 0 && Array.isArray(c.extra_ports)) {
      const newExtra: Array<{ port: number; protocol: Protocol }> = [];
      let changed = false;
      for (const ep of c.extra_ports) {
        const portNum = typeof ep === "number" ? ep : ep?.port;
        const existingProto = typeof ep === "object" ? ep?.protocol : undefined;
        const draftMatch = extraPorts.find(d => d.port === portNum);
        if (!draftMatch) {
          // No draft entry — preserve as object
          newExtra.push(typeof ep === "object" ? ep : { port: portNum, protocol: "http" });
          continue;
        }
        if (typeof ep === "number" || existingProto !== draftMatch.protocol) {
          changed = true;
        }
        newExtra.push({ port: portNum, protocol: draftMatch.protocol });
      }
      if (changed) {
        c.extra_ports = newExtra;
        writes.push(`containers.${dc.container_key}.extra_ports → PortSpec[]`);
      }
    }

    // 3. l4_ports[] — attach protocol (only for single-container services)
    if (l4Ports.length > 0 && bj.proxy?.primary?.l4_ports) {
      for (const entry of bj.proxy.primary.l4_ports) {
        const draftMatch = l4Ports.find(d => d.port === entry.port);
        if (draftMatch && entry.protocol !== draftMatch.protocol) {
          entry.protocol = draftMatch.protocol;
          writes.push(`proxy.primary.l4_ports[port=${entry.port}].protocol = "${draftMatch.protocol}"`);
        }
      }
    }
  }
  return { changed: writes.length > 0, writes };
}

function main() {
  const draft: Draft = JSON.parse(readFileSync(DRAFT_FILE, "utf-8"));

  // Validate draft: every port must have a protocol in the enum
  for (const s of draft.services) {
    for (const c of s.containers) {
      for (const p of c.ports) {
        if (!ENUM.includes(p.protocol)) {
          console.error(`Invalid protocol "${p.protocol}" at ${s.service}/${c.container_name}:${p.port}`);
          process.exit(2);
        }
      }
    }
  }

  let servicesChanged = 0;
  let totalWrites = 0;
  for (const svc of draft.services) {
    const bjPath = join(SOLUTIONS_DIR, svc.folder, "build.json");
    let bj: any;
    try { bj = JSON.parse(readFileSync(bjPath, "utf-8")); } catch { continue; }
    const { changed, writes } = applyToBuildJson(bj, svc);
    if (!changed) continue;

    servicesChanged++;
    totalWrites += writes.length;
    console.log(`\n${dry ? "[DRY] " : ""}${svc.service}  (${writes.length} change${writes.length > 1 ? "s" : ""})`);
    for (const w of writes) console.log(`    + ${w}`);

    if (!dry) {
      writeFileSync(bjPath, JSON.stringify(bj, null, 2) + "\n");
    }
  }

  console.log(`\n═════════════════════════════════════════════════`);
  console.log(`${dry ? "Would modify" : "Modified"} ${servicesChanged} services · ${totalWrites} writes`);
  if (dry) console.log(`\nRe-run without --dry to apply.`);
}

main();
