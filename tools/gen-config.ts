// gen-config.ts - Declarative config generator
//
// Sources:
//   ~/.ssh/config                            -> VM aliases + WireGuard IPs
//   a_solutions/{service}/build.json         -> service metadata (category, domain, deploy host)
//   a_solutions/{service}/dist/compose.yml   -> container names (if built)
//
// Outputs:
//   config.json  - machine-readable infrastructure config
//   config.md    - human-readable documentation (via Nunjucks template)

import { readFileSync, writeFileSync, readdirSync, existsSync } from "fs";
import { resolve, join, basename } from "path";
import { parse as parseYaml } from "yaml";
import nunjucks from "nunjucks";
import { execSync } from "child_process";
import { homedir } from "os";

// --- Paths ----------------------------------------------------------------

const CLOUD_ROOT = resolve(import.meta.dirname!, "..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const TOOLS_DIR = import.meta.dirname!;
const CONFIG_JSON = join(CLOUD_ROOT, "config.json");
const CONFIG_MD = join(CLOUD_ROOT, "config.md");
const TEMPLATE = join(TOOLS_DIR, "config.md.njk");

// SSH config: local ~/.ssh/config (symlinked from vault)
const SSH_CONFIG = join(homedir(), ".ssh", "config");

// --- Types ----------------------------------------------------------------

interface VM {
  ip: string;
  wg_ip: string;
  user: string;
  method: string;
  ssh_alias: string;
  description: string;
  [key: string]: unknown;
}

interface Service {
  category: string;
  vm: string;
  containers: string[];
  description: string;
  domain?: string;
  flake?: string;
  [key: string]: unknown;
}

interface BuildJson {
  name: string;
  description: string;
  category?: string;
  domain?: string;
  multi_vm?: boolean;
  deploy: {
    host: string;
    remote_path: string;
  };
}

interface Config {
  ssh_key: string;
  remote_base: string;
  vms: Record<string, VM>;
  native: Record<string, unknown>;
  vpss: Record<string, unknown>;
  services: Record<string, Service>;
}

// --- Category prefix map --------------------------------------------------

const CATEGORY_PREFIX: Record<string, string> = {
  app: "aa-sui_",
  mic: "ab-mic_",
  fin: "ac-fin_",
  agi: "ad-agi_",
  cloud: "ba-clo_",
  sec: "bb-sec_",
  tools: "bc-obs_",
  data: "ca-dat_",
};

// Reverse: prefix -> category
const PREFIX_CATEGORY: Record<string, string> = {};
for (const [cat, prefix] of Object.entries(CATEGORY_PREFIX)) {
  PREFIX_CATEGORY[prefix] = cat;
}

// --- SSH Config Parser ----------------------------------------------------

interface SSHHost {
  alias: string;
  hostname: string;
  user: string;
  identityFile: string;
  commented: boolean;
}

function parseSSHConfig(path: string): SSHHost[] {
  if (!existsSync(path)) return [];
  const content = readFileSync(path, "utf-8");
  const hosts: SSHHost[] = [];
  let current: Partial<SSHHost> | null = null;
  let inComment = false;

  for (const line of content.split("\n")) {
    const trimmed = line.trim();

    // Detect commented-out Host blocks (decommissioned)
    const commentedHost = trimmed.match(/^#\s*Host\s+(\S+)/);
    if (commentedHost) {
      if (current?.alias) hosts.push(current as SSHHost);
      current = { alias: commentedHost[1], commented: true };
      inComment = true;
      continue;
    }

    const hostMatch = trimmed.match(/^Host\s+(\S+)/);
    if (hostMatch) {
      if (current?.alias) hosts.push(current as SSHHost);
      current = { alias: hostMatch[1], commented: false };
      inComment = false;
      continue;
    }

    if (!current) continue;

    // Parse both commented and uncommented directives within a host block
    const directive = inComment ? trimmed.replace(/^#\s*/, "") : trimmed;
    const kvMatch = directive.match(/^(\w+)\s+(.+)$/);
    if (kvMatch) {
      const [, key, value] = kvMatch;
      switch (key.toLowerCase()) {
        case "hostname":
          current.hostname = value;
          break;
        case "user":
          current.user = value;
          break;
        case "identityfile":
          current.identityFile = value;
          break;
      }
    }

    // End of commented block when we hit a non-comment, non-empty line
    if (inComment && trimmed !== "" && !trimmed.startsWith("#")) {
      inComment = false;
    }
  }
  if (current?.alias) hosts.push(current as SSHHost);

  // Filter out non-VM hosts (github.com, etc.)
  return hosts.filter(
    (h) => h.hostname && !h.alias.includes(".") && h.alias !== "*"
  );
}

// --- Build.json Scanner ---------------------------------------------------

function scanBuildJsons(): Map<string, BuildJson> {
  const map = new Map<string, BuildJson>();
  for (const folder of readdirSync(SOLUTIONS_DIR)) {
    if (folder.startsWith("z_archive") || folder.startsWith(".")) continue;
    const bjPath = join(SOLUTIONS_DIR, folder, "build.json");
    if (!existsSync(bjPath)) continue;
    try {
      const bj: BuildJson = JSON.parse(readFileSync(bjPath, "utf-8"));
      map.set(folder, bj);
    } catch {
      console.warn(`  WARN: invalid build.json in ${folder}`);
    }
  }
  return map;
}

// --- Docker Compose Parser ------------------------------------------------

function getContainers(folder: string): string[] {
  const composePath = join(SOLUTIONS_DIR, folder, "dist", "docker-compose.yml");
  if (!existsSync(composePath)) return [];
  try {
    const doc = parseYaml(readFileSync(composePath, "utf-8"));
    if (!doc?.services) return [];
    const containers: string[] = [];
    for (const [svcName, svcDef] of Object.entries(doc.services) as [
      string,
      any
    ][]) {
      containers.push(svcDef?.container_name || svcName);
    }
    return containers.sort();
  } catch {
    return [];
  }
}

// --- VM ID mapping --------------------------------------------------------

// SSH alias -> VM ID (from existing config.json, preserved)
function loadExistingVMMap(configPath: string): Record<string, string> {
  if (!existsSync(configPath)) return {};
  try {
    const config = JSON.parse(readFileSync(configPath, "utf-8"));
    const map: Record<string, string> = {};
    for (const [vmId, vm] of Object.entries(config.vms || {}) as [
      string,
      any
    ][]) {
      if (vm.ssh_alias) map[vm.ssh_alias] = vmId;
    }
    return map;
  } catch {
    return {};
  }
}

// --- Main -----------------------------------------------------------------

function main() {
  console.log("gen-config: scanning sources...");

  // 1. Load existing config to preserve manual fields (descriptions, gcloud, gpu, etc.)
  let existing: Config | null = null;
  if (existsSync(CONFIG_JSON)) {
    existing = JSON.parse(readFileSync(CONFIG_JSON, "utf-8"));
  }

  // 2. Parse SSH config for VM data
  const sshHosts = parseSSHConfig(SSH_CONFIG);
  const aliasToVmId = loadExistingVMMap(CONFIG_JSON);
  console.log(
    `  SSH config: ${sshHosts.filter((h) => !h.commented).length} active hosts, ${sshHosts.filter((h) => h.commented).length} commented`
  );

  // 3. Update VMs from SSH config (merge with existing, SSH is source of truth for IPs)
  const vms: Record<string, VM> = {};
  for (const host of sshHosts) {
    if (host.commented) continue;
    const vmId = aliasToVmId[host.alias];
    if (!vmId) {
      console.warn(
        `  WARN: SSH alias '${host.alias}' not mapped to a VM ID in config.json - skipping`
      );
      continue;
    }

    const existingVm = existing?.vms?.[vmId];
    vms[vmId] = {
      ...existingVm,
      ip: existingVm?.ip || "", // Preserve public IP if set (don't overwrite from SSH)
      wg_ip: host.hostname, // SSH config has WG IPs
      user: host.user,
      method: existingVm?.method || "key",
      ssh_alias: host.alias,
      description: existingVm?.description || "",
    } as VM;
  }

  // Also preserve VMs that are in existing config but not in SSH (e.g. vast-ai)
  if (existing?.vms) {
    for (const [vmId, vm] of Object.entries(existing.vms)) {
      if (!vms[vmId]) {
        vms[vmId] = vm;
      }
    }
  }

  // 4. Scan build.json files for services
  const buildJsons = scanBuildJsons();
  console.log(`  build.json: ${buildJsons.size} services found`);

  // 5. Build services map
  const services: Record<string, Service> = {};

  for (const [folder, bj] of buildJsons) {
    const serviceName = bj.name;
    const category =
      bj.category || deriveCategory(folder) || existing?.services?.[serviceName]?.category || "tools";
    const host = bj.deploy.host;

    // Find VM ID from SSH alias
    const vmId =
      host === "local" || host === "all"
        ? host
        : aliasToVmId[host] || findVmIdByAlias(host, vms) || host;

    // Get containers from dist/docker-compose.yml
    const containers = getContainers(folder);

    // Determine flake override (when folder name doesn't match service name with prefix)
    const expectedFolder = CATEGORY_PREFIX[category]
      ? `${CATEGORY_PREFIX[category]}${serviceName}`
      : serviceName;
    const flake = folder !== expectedFolder ? folder.replace(/^[a-z]{2}-[a-z]{3}_/, "") : undefined;

    // Merge with existing service data (preserve manual fields)
    const existingSvc = existing?.services?.[serviceName];

    const svc: Service = {
      category,
      vm: vmId,
      ...(containers.length > 0 ? { containers } : existingSvc?.containers ? { containers: existingSvc.containers } : {}),
      ...(bj.domain ? { domain: bj.domain } : existingSvc?.domain ? { domain: existingSvc.domain } : {}),
      description: bj.description || existingSvc?.description || "",
      ...(flake ? { flake } : existingSvc?.flake ? { flake: existingSvc.flake } : {}),
    };

    // Preserve extra fields from existing config (api_port, models, notes, etc.)
    if (existingSvc) {
      for (const [k, v] of Object.entries(existingSvc)) {
        if (!(k in svc)) {
          (svc as any)[k] = v;
        }
      }
    }

    services[serviceName] = svc;
  }

  // Handle multi_vm services (sauron-lite, db-agent, syslog-forwarder)
  // These are in build.json with multi_vm=true but config.json has per-VM entries
  // Preserve existing per-VM entries that aren't covered by a build.json
  if (existing?.services) {
    for (const [name, svc] of Object.entries(existing.services)) {
      if (!services[name]) {
        // Check if this is a per-VM instance of a multi_vm service
        services[name] = svc;
      }
    }
  }

  // 6. Assemble final config (preserve key ordering)
  const config: Config = {
    ssh_key: existing?.ssh_key || detectSSHKey(),
    remote_base: existing?.remote_base || "/opt/containers",
    vms,
    native: existing?.native || {},
    vpss: existing?.vpss || {},
    services,
  };

  // 7. Write config.json (preserve key order)
  writeFileSync(CONFIG_JSON, JSON.stringify(config, null, 2) + "\n");
  console.log(`  Written: config.json (${Object.keys(services).length} services, ${Object.keys(vms).length} VMs)`);

  // 8. Render config.md from Nunjucks template
  if (existsSync(TEMPLATE)) {
    nunjucks.configure(TOOLS_DIR, { autoescape: false, trimBlocks: true, lstripBlocks: true });
    const md = nunjucks.render("config.md.njk", { config, CATEGORY_PREFIX, PREFIX_CATEGORY });
    writeFileSync(CONFIG_MD, md);
    console.log(`  Written: config.md`);
  } else {
    console.warn(`  WARN: template not found at ${TEMPLATE}, skipping config.md`);
  }

  console.log("gen-config: done.");
}

// --- Helpers --------------------------------------------------------------

function deriveCategory(folder: string): string | undefined {
  for (const [prefix, cat] of Object.entries(PREFIX_CATEGORY)) {
    if (folder.startsWith(prefix)) return cat;
  }
  return undefined;
}

function findVmIdByAlias(
  alias: string,
  vms: Record<string, VM>
): string | undefined {
  for (const [id, vm] of Object.entries(vms)) {
    if (vm.ssh_alias === alias) return id;
  }
  return undefined;
}

function detectSSHKey(): string {
  const candidates = [
    join(homedir(), ".ssh", "id_rsa"),
    join(homedir(), "git", "vault", "A0_keys", "ssh", "id_rsa"),
    "/home/diego/Mounts/Git/vault/A0_keys/ssh/id_rsa",
  ];
  return candidates.find((p) => existsSync(p)) || candidates[0];
}

main();
