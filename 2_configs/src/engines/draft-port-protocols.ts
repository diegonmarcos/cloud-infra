// draft-port-protocols.ts — Generate a protocol-inference draft for human review.
//
// Walks every build.json, classifies every port by heuristic, emits a single
// JSON file grouped by service → container → ports. Review the draft, correct
// any "review: true" entries, then run apply-port-protocols.ts to push the
// approved protocols back into each build.json.
//
// READ-ONLY. Writes only to: port-protocol-draft.json (this directory)
//
// Run: npx tsx draft-port-protocols.ts

import { readFileSync, readdirSync, statSync, writeFileSync } from "fs";
import { resolve, join } from "path";

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT = resolve(ENGINE_DIR, "../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT, "..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const OUTPUT = join(ENGINE_DIR, "port-protocol-draft.json");

type Protocol = "http" | "https" | "tls" | "starttls" | "tcp" | "udp";

interface PortDraft {
  location: "primary" | "extra" | "l4";
  location_path: string;         // e.g. "containers.app.port"
  port: number;
  protocol: Protocol;
  reason: string;                // why the classifier picked this
  review: boolean;               // true if classifier fell back to default (uncertain)
  comment?: string;              // passed-through from l4_ports or service notes
}

interface ContainerDraft {
  container_key: string;
  container_name: string;
  image?: string;
  ports: PortDraft[];
}

interface ServiceDraft {
  service: string;
  vm?: string;
  folder: string;
  containers: ContainerDraft[];
}

const DB_IMAGE_RX = /postgres|mariadb|mysql|mongo|redis|valkey|surrealdb|memcached|postlite/i;

// Alternate/non-standard mail ports used by services that coexist with another mail server.
// Maps port number → standard protocol it mirrors. Used only when the container is identified as mail-server-like.
const ALT_MAIL_PORTS: Record<number, Protocol> = {
  2025: "starttls",  // alternate SMTP inbound (mirrors 25)
  2465: "tls",       // alternate SMTPS (mirrors 465)
  2587: "starttls",  // alternate Submission (mirrors 587)
  2993: "tls",       // alternate IMAPS (mirrors 993)
};
const MAIL_IMAGE_RX = /stalwart|maddy|postfix|dovecot|mailu|mailcow/i;

function classify(
  port: number,
  container: any,
  l4Comment?: string,
): { protocol: Protocol; reason: string; review: boolean } {
  // 1. l4_ports comment
  if (l4Comment) {
    const c = l4Comment.toLowerCase();
    if (/imaps|smtps|pop3s|managesieve|sieve/.test(c)) return { protocol: "tls", reason: `l4_comment matches TLS term ("${l4Comment}")`, review: false };
    if (/starttls|submission/.test(c)) return { protocol: "starttls", reason: `l4_comment matches STARTTLS term ("${l4Comment}")`, review: false };
    if (/\bhttps\b/.test(c)) return { protocol: "https", reason: `l4_comment mentions HTTPS ("${l4Comment}")`, review: false };
    if (/\bsmtp\b/.test(c) && !/smtps/.test(c)) return { protocol: "starttls", reason: `l4_comment mentions plain SMTP → STARTTLS ("${l4Comment}")`, review: false };
  }
  // 2. DB image
  if (typeof container?.image === "string" && DB_IMAGE_RX.test(container.image)) {
    return { protocol: "tcp", reason: `image "${container.image}" matches DB regex`, review: false };
  }
  // 2b. Mail image + alternate mail port (stalwart-style coexistence variants)
  if (typeof container?.image === "string" && MAIL_IMAGE_RX.test(container.image) && ALT_MAIL_PORTS[port]) {
    return { protocol: ALT_MAIL_PORTS[port], reason: `mail image "${container.image}" + alternate mail port ${port}`, review: false };
  }
  // 3. Well-known IANA ports (standards only)
  if ([443, 2443, 8443].includes(port)) return { protocol: "https", reason: `port ${port} is a well-known HTTPS port`, review: false };
  if ([993, 465, 995, 6190].includes(port)) return { protocol: "tls", reason: `port ${port} is well-known implicit-TLS (IMAPS/SMTPS/POP3S/ManageSieve)`, review: false };
  if ([587, 143, 110, 25].includes(port)) return { protocol: "starttls", reason: `port ${port} is well-known STARTTLS`, review: false };
  if ([5432, 3306, 27017, 1433, 11211, 6379].includes(port)) return { protocol: "tcp", reason: `port ${port} is well-known DB/cache (plaintext TCP)`, review: false };
  if (port === 53) return { protocol: "udp", reason: `port 53 is DNS (UDP primary)`, review: false };
  // 4. Default → http, flagged for review
  return { protocol: "http", reason: `no heuristic matched — defaulted to http (REVIEW)`, review: true };
}

function draftForService(folder: string, bj: any): ServiceDraft | null {
  if (!bj.name) return null;
  const containers = bj.containers ?? {};
  if (Object.keys(containers).length === 0) return null;

  const isSingle = Object.keys(containers).length === 1;
  const containerDrafts: ContainerDraft[] = [];

  for (const [ck, c] of Object.entries(containers) as [string, any][]) {
    const ports: PortDraft[] = [];
    const seenPerLocation: Record<string, Set<number>> = { primary: new Set(), extra: new Set(), l4: new Set() };
    const pushPort = (p: number, location: PortDraft["location"], path: string, l4Comment?: string) => {
      if (seenPerLocation[location].has(p)) return;
      seenPerLocation[location].add(p);
      const { protocol, reason, review } = classify(p, c, l4Comment);
      ports.push({ location, location_path: path, port: p, protocol, reason, review, ...(l4Comment ? { comment: l4Comment } : {}) });
    };

    if (typeof c.port === "number") {
      pushPort(c.port, "primary", `containers.${ck}.port`);
    }
    for (const ep of (c.extra_ports ?? []) as number[]) {
      if (typeof ep === "number") pushPort(ep, "extra", `containers.${ck}.extra_ports[]`);
    }
    // L4 ports attribute only to single-container services
    if (isSingle) {
      const l4 = bj.proxy?.primary?.l4_ports ?? [];
      for (const entry of l4) {
        if (typeof entry.port === "number") pushPort(entry.port, "l4", `proxy.primary.l4_ports[]`, entry.comment);
      }
    }

    containerDrafts.push({
      container_key: ck,
      container_name: c.container_name,
      image: c.image ?? undefined,
      ports,
    });
  }

  return {
    service: bj.name,
    vm: bj.deploy?.host,
    folder,
    containers: containerDrafts,
  };
}

function main() {
  const dirs = readdirSync(SOLUTIONS_DIR).sort().filter(d => {
    try { return statSync(join(SOLUTIONS_DIR, d)).isDirectory(); } catch { return false; }
  });

  const services: ServiceDraft[] = [];
  for (const d of dirs) {
    let bj: any;
    try { bj = JSON.parse(readFileSync(join(SOLUTIONS_DIR, d, "build.json"), "utf-8")); } catch { continue; }
    const draft = draftForService(d, bj);
    if (draft) services.push(draft);
  }

  // Stats
  let totalPorts = 0;
  let toReview = 0;
  const protoCounts: Record<Protocol, number> = { http: 0, https: 0, tls: 0, starttls: 0, tcp: 0, udp: 0 };
  for (const s of services) {
    for (const c of s.containers) {
      for (const p of c.ports) {
        totalPorts++;
        if (p.review) toReview++;
        protoCounts[p.protocol]++;
      }
    }
  }

  const output = {
    _meta: {
      description: "Protocol-inference draft for port declarations. Review entries with review=true and correct their protocol. Then run apply-port-protocols.ts to write back into build.json files.",
      generated: (() => {
        // Reproducible timestamp — see cloud-data-config-derive.ts:`now`.
        const _sde = process.env.SOURCE_DATE_EPOCH;
        return (_sde && /^\d+$/.test(_sde))
          ? new Date(Number(_sde) * 1000).toISOString()
          : new Date().toISOString();
      })(),
      enum_values: ["http", "https", "tls", "starttls", "tcp", "udp"],
      stats: {
        services: services.length,
        containers: services.reduce((a, s) => a + s.containers.length, 0),
        ports: totalPorts,
        to_review: toReview,
        by_protocol: protoCounts,
      },
    },
    services,
  };

  writeFileSync(OUTPUT, JSON.stringify(output, null, 2));
  console.log(`Wrote draft → ${OUTPUT}`);
  console.log(`  ${services.length} services · ${output._meta.stats.containers} containers · ${totalPorts} ports`);
  console.log(`  To review: ${toReview}`);
  console.log(`  By protocol: ${Object.entries(protoCounts).map(([k, v]) => `${k}=${v}`).join(" ")}`);

  if (toReview > 0) {
    console.log(`\nEntries needing review (non-standard ports that defaulted to http):`);
    for (const s of services) {
      const reviewPorts = s.containers.flatMap(c => c.ports.filter(p => p.review).map(p => ({ c, p })));
      if (reviewPorts.length === 0) continue;
      console.log(`\n  ${s.service} (${s.vm ?? "?"})`);
      for (const { c, p } of reviewPorts) {
        console.log(`    [${c.container_name}:${p.port}] ← ${p.location_path}   (default: http)`);
      }
    }
  }
}

main();
