// preview-app-urls.ts — Strict port-declaration preview.
//
// For each container across every build.json, synthesize:
//   {container_name}.app                              — ALWAYS an HTTPS redirect to the first canonical URL
//                                                       (redundant alias, not a primary route)
//   {container_name}-{protocol}-{port}.app            — canonical per-port entry
//                                                       (protocol: http|https|tls|starttls|tcp|udp)
//   {container_name}-null.app                         — explicit marker for portless workers/sidecars
//
// Protocol is read from build.json:
//   - containers.<x>.protocol            (sibling of containers.<x>.port)
//   - containers.<x>.extra_ports[].protocol
//   - proxy.primary.l4_ports[].protocol
//
// Ports are "owned" by a container if they come from:
//   - containers.<key>.port                (primary declared port)
//   - containers.<key>.extra_ports[]       (secondary ports on the same container)
//   - proxy.primary.l4_ports[].port        ONLY if service has exactly 1 container
//                                          (single-container services get L4 attribution)
//
// Top-level `bj.port` and `bj.ports{}` are NOT inherited. They're reported as
// "orphan" only if their value doesn't match any container's declared port.
//
// READ-ONLY. Prints table, flags containers missing port declarations.
//
// Run: npx tsx preview-app-urls.ts
//      npx tsx preview-app-urls.ts --service maddy,stalwart
//      npx tsx preview-app-urls.ts --only-issues    # only flag the bad ones

import { readFileSync, readdirSync, statSync } from "fs";
import { resolve, join } from "path";

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT = resolve(ENGINE_DIR, "../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT, "..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");

const args = process.argv.slice(2);
const filterIdx = args.indexOf("--service");
const serviceFilter = filterIdx >= 0 ? new Set(args[filterIdx + 1].split(",")) : null;
const onlyIssues = args.includes("--only-issues");

interface Issue {
  service: string;
  kind: "ORPHAN_TOP_PORT" | "ORPHAN_TOP_PORTS_MAP" | "L4_MULTI_CONTAINER";
  detail: string;
}

type Protocol = "http" | "https" | "tls" | "starttls" | "tcp" | "udp";

function synthForService(bj: any) {
  const service = bj.name;
  const vm = bj.deploy?.host ?? "?";
  const containers = bj.containers ?? {};
  const containerEntries = Object.entries(containers) as [string, any][];
  const isSingle = containerEntries.length === 1;

  // Per-container owned ports
  interface ContainerInfo {
    key: string;
    name: string;
    ports: Array<{ port: number; protocol: Protocol; source: string }>;
    urls: Array<{ name: string; source: string }>;
  }
  const cInfos: ContainerInfo[] = [];

  for (const [ck, c] of containerEntries) {
    const ports: Array<{ port: number; protocol: Protocol; source: string }> = [];
    const seen = new Set<number>();
    const add = (p: number | null | undefined, proto: Protocol, src: string) => {
      if (typeof p !== "number" || seen.has(p)) return;
      seen.add(p);
      ports.push({ port: p, protocol: proto, source: src });
    };

    if (typeof c.port === "number") {
      if (!c.protocol) {
        console.error(`MISSING PROTOCOL: ${bj.name}/${c.container_name} port ${c.port}`);
        process.exit(2);
      }
      add(c.port, c.protocol as Protocol, `containers.${ck}.port`);
    }
    // Secondary ports on the same container
    for (const ep of (c.extra_ports ?? []) as Array<{ port: number; protocol: Protocol }>) {
      if (typeof ep !== "object" || !ep.protocol) {
        console.error(`MISSING PROTOCOL: ${bj.name}/${c.container_name} extra_port ${JSON.stringify(ep)}`);
        process.exit(2);
      }
      add(ep.port, ep.protocol, `containers.${ck}.extra_ports`);
    }
    // L4 ports attribute only to single-container services
    if (isSingle) {
      const l4 = bj.proxy?.primary?.l4_ports ?? [];
      for (const e of l4) {
        if (!e.protocol) {
          console.error(`MISSING PROTOCOL: ${bj.name}/${c.container_name} l4_port ${e.port}`);
          process.exit(2);
        }
        add(e.port, e.protocol as Protocol, `proxy.primary.l4_ports`);
      }
    }

    // Redirect target: always the first canonical URL
    const first = ports[0];
    const redirectTarget = first
      ? `${c.container_name}-${first.protocol}-${first.port}.app`
      : `${c.container_name}-null.app`;

    const urls: Array<{ name: string; source: string }> = [];
    urls.push({
      name: `${c.container_name}.app`,
      source: `redirect → https://${redirectTarget}`,
    });
    if (ports.length === 0) {
      urls.push({ name: `${c.container_name}-null.app`, source: "portless marker" });
    } else {
      for (const { port, protocol, source } of ports) {
        urls.push({ name: `${c.container_name}-${protocol}-${port}.app`, source: `${source} (proto=${protocol})` });
      }
    }
    cInfos.push({ key: ck, name: c.container_name, ports, urls });
  }

  // ── Detect issues ──
  const issues: Issue[] = [];

  // Containers with no port are valid (workers/sidecars) — they emit {container}-null.app.
  // Only flag if there's a top-level port that points at this container but isn't declared on it.

  // Issue: top-level bj.port that doesn't match any container's port
  if (typeof bj.port === "number") {
    const allPorts = new Set(cInfos.flatMap(ci => ci.ports.map(p => p.port)));
    if (!allPorts.has(bj.port)) {
      issues.push({
        service,
        kind: "ORPHAN_TOP_PORT",
        detail: `top-level port=${bj.port} not in any container's port (containers: ${[...allPorts].join(",") || "none"})`,
      });
    }
  }

  // Issue 3: top-level ports{} map entries that don't match any container's port
  if (bj.ports && typeof bj.ports === "object") {
    const allPorts = new Set(cInfos.flatMap(ci => ci.ports.map(p => p.port)));
    for (const [pk, pv] of Object.entries(bj.ports) as [string, any][]) {
      const n = typeof pv === "number" ? pv : pv?.port;
      if (typeof n !== "number") continue;
      if (!allPorts.has(n)) {
        issues.push({
          service,
          kind: "ORPHAN_TOP_PORTS_MAP",
          detail: `top-level ports.${pk}=${n} not in any container's port`,
        });
      }
    }
  }

  // Issue 4: multi-container service with l4_ports (ambiguous attribution)
  if (!isSingle && (bj.proxy?.primary?.l4_ports?.length ?? 0) > 0) {
    issues.push({
      service,
      kind: "L4_MULTI_CONTAINER",
      detail: `service has proxy.primary.l4_ports but ${containerEntries.length} containers — can't attribute ports to a specific container`,
    });
  }

  return { service, vm, cInfos, issues };
}

function main() {
  const dirs = readdirSync(SOLUTIONS_DIR).sort().filter(d => {
    try { return statSync(join(SOLUTIONS_DIR, d)).isDirectory(); } catch { return false; }
  });

  const allServices: Array<ReturnType<typeof synthForService>> = [];
  const allIssues: Issue[] = [];

  for (const d of dirs) {
    let bj: any;
    try { bj = JSON.parse(readFileSync(join(SOLUTIONS_DIR, d, "build.json"), "utf-8")); } catch { continue; }
    if (!bj.name) continue;
    if (serviceFilter && !serviceFilter.has(bj.name)) continue;
    // Skip services without containers
    if (!bj.containers || Object.keys(bj.containers).length === 0) continue;

    const r = synthForService(bj);
    allServices.push(r);
    allIssues.push(...r.issues);
  }

  // ── Print table (optionally only services with issues) ──
  for (const r of allServices) {
    if (onlyIssues && r.issues.length === 0) continue;
    const hasIssues = r.issues.length > 0;
    const marker = hasIssues ? "⚠" : "✓";
    console.log(`\n${marker} ${r.service} (${r.vm})`);
    for (const ci of r.cInfos) {
      const portless = ci.ports.length === 0 ? "  (portless — worker/sidecar)" : "";
      console.log(`  [${ci.key}] container_name=${ci.name}${portless}`);
      for (const u of ci.urls) {
        console.log(`    ${u.name.padEnd(44)} ← ${u.source}`);
      }
    }
    for (const is of r.issues) {
      console.log(`  ⚠ ${is.kind}: ${is.detail}`);
    }
  }

  // ── Summary ──
  console.log(`\n═══════════════════════════════════════════════════`);
  console.log(`Services scanned:       ${allServices.length}`);
  console.log(`Containers:             ${allServices.reduce((a, r) => a + r.cInfos.length, 0)}`);
  console.log(`URLs synthesized:       ${allServices.reduce((a, r) => a + r.cInfos.reduce((b, ci) => b + ci.urls.length, 0), 0)}`);
  console.log(`Issues:                 ${allIssues.length}`);

  const byKind: Record<string, Issue[]> = {};
  for (const i of allIssues) (byKind[i.kind] ??= []).push(i);

  for (const [kind, list] of Object.entries(byKind)) {
    console.log(`\n── ${kind} (${list.length}) ──`);
    for (const i of list) {
      console.log(`  [${i.service}] ${i.detail}`);
    }
  }

  process.exit(allIssues.length > 0 ? 1 : 0);
}

main();
