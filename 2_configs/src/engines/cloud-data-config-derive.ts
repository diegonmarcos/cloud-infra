// cloud-data-config-derive.ts — Derive ALL per-consumer JSON files from consolidated
//
// Input:  cloud-data/_cloud-data-consolidated.json
// Output: cloud-data/cloud-data-*.json (18 files)
//
// Run: tsx cloud-data-config-derive.ts

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { resolve, join } from "path";

// ═══════════════════════════════════════════════════════════════════════════
// Paths
// ═══════════════════════════════════════════════════════════════════════════

const ENGINE_DIR = import.meta.dirname!;
// Script lives at: cloud/2_configs/src/engines — 2 levels up = cloud/2_configs
const CONFIGS_DIR = resolve(ENGINE_DIR, "../..");
const CLOUD_ROOT = resolve(CONFIGS_DIR, "..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT, "..");
const CLOUD_DATA_DIR = join(CONFIGS_DIR, "dist");             // dist root (build-*.json + manifest)
// `cloud-data-{name}.json` files are on the deprecation track. They keep
// generating for soft-transition compat (consumers migrate per-service to
// read their own build-{containername}.json), but their on-disk location
// is dist/z_archive/ — making the archived status visible at the FS layer.
// Every consumer's path-priority chain has been updated to look in z_archive.
//
// Do NOT add new derive functions whose output starts with "cloud-data-";
// enrich `deriveContainerConfigs` / `deriveServiceConnections` instead so
// the data flows into every build-{name}.json.
const ARCHIVE_DIR = join(CLOUD_DATA_DIR, "z_archive");
const INPUT_JSON = join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json");

/** Files starting with "cloud-data-" are archived (write to dist/z_archive/);
 *  everything else (build-*, _cloud-data-consolidated, manifest) stays at dist/ root. */
function targetDirFor(fileName: string): string {
  return fileName.startsWith("cloud-data-") ? ARCHIVE_DIR : CLOUD_DATA_DIR;
}

// ═══════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════

interface DerivedFile {
  name: string;
  data: unknown;
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

function now(): string {
  return new Date().toISOString();
}

/** Build ssh_alias → vm entry map */
function buildAliasToVm(vms: Record<string, any>): Record<string, { vmId: string; vm: any }> {
  const map: Record<string, { vmId: string; vm: any }> = {};
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias) map[vm.ssh_alias] = { vmId, vm };
  }
  return map;
}

/** Build vmId → ssh_alias map */
function buildVmIdToAlias(vms: Record<string, any>): Record<string, string> {
  const map: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias) map[vmId] = vm.ssh_alias;
  }
  return map;
}

// ═══════════════════════════════════════════════════════════════════════════
// Derivation functions
// ═══════════════════════════════════════════════════════════════════════════

function deriveSecretsEnvVarNames(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  const perService: any[] = [];
  const byVm: Record<string, any[]> = {};
  let totalVars = 0;

  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    const envVars: string[] = svc.secret_env_vars ?? [];
    if (envVars.length === 0) continue;

    const vmAlias = vmIdToAlias[svc.vm] ?? svc.vm;
    const hasEnvFile = Object.values(svc.containers ?? {}).some((ct: any) => ct.env_file);

    const entry = {
      service: svcName,
      folder: svc.folder,
      vm: vmAlias,
      env_file: hasEnvFile,
      env_vars: envVars,
      count: envVars.length,
    };

    perService.push(entry);
    totalVars += envVars.length;

    if (!byVm[vmAlias]) byVm[vmAlias] = [];
    byVm[vmAlias].push(entry);
  }

  return {
    name: "cloud-data-secrets-env-var-names.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/secrets-env-var-names",
      total_services: perService.length,
      total_env_vars: totalVars,
      services: perService,
      by_vm: byVm,
    },
  };
}

function deriveDatabases(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  // ── Data store type detection (100% declared, zero image regex) ─────────
  // Priority: containers.<x>.db_engine > containers.<x>.embedded_dbs[0].engine
  //         > legacy ct.db_path signals sqlite > ct.dump_cmd signals "custom"
  function inferDbType(ct: any): string | null {
    if (ct.db_engine) return ct.db_engine;
    if (Array.isArray(ct.embedded_dbs) && ct.embedded_dbs[0]?.engine) return ct.embedded_dbs[0].engine;
    if (ct.db_path) return "sqlite";
    if (ct.dump_cmd) return "custom";
    return null;
  }

  function isDataStore(ct: any): boolean {
    return !!(ct.db_engine || ct.embedded_dbs?.length || ct.db_user || ct.db_name || ct.db_path || ct.dump_cmd);
  }

  // ── Scan all services ──────────────────────────────────────────────────
  const databases: any[] = [];
  const byType: Record<string, any[]> = {};
  const byVm: Record<string, { wg_ip: string; user: string; databases: any[] }> = {};
  const summary: Record<string, number> = {
    postgres: 0, mariadb: 0, redis: 0, sqlite: 0, surrealdb: 0,
    custom: 0, mongo: 0, s3: 0, loki: 0, mimir: 0, tempo: 0, grafana: 0,
  };

  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    const vmAlias = vmIdToAlias[svc.vm] ?? svc.vm;
    const vm = vms[svc.vm];
    const enabled = svc.enabled !== false;

    if (!svc.containers) continue;

    for (const [ctKey, ct] of Object.entries(svc.containers) as [string, any][]) {
      if (!isDataStore(ct)) continue;

      const type = inferDbType(ct) ?? "custom";
      const port = ct.port ?? svc.declared_ports?.[ctKey] ?? null;
      const dns = ct.dns ?? null;

      const entry: any = {
        service: svcName,
        container: ct.container_name,
        container_key: ctKey,
        type,
        enabled,
        vm: svc.vm,
        vm_alias: vmAlias,
        wg_ip: vm?.wg_ip ?? null,
        image: ct.image ?? null,
        port,
        dns,
        ...(ct.db_user ? { user: ct.db_user } : {}),
        ...(ct.db_name ? { db: ct.db_name } : {}),
        ...(ct.db_path ? { path: ct.db_path } : {}),
        ...(ct.dump_cmd ? { dump_cmd: ct.dump_cmd } : {}),
        ...(ct.healthcheck ? { healthcheck: ct.healthcheck } : {}),
        volumes: ct.volumes ?? [],
        resources: ct.resources ?? null,
        backup: svc.backup?.enabled ?? false,
      };

      // Connection string hint
      if (type === "postgres" && ct.db_user && ct.db_name && vm?.wg_ip && port) {
        entry.connection = `postgresql://${ct.db_user}@${vm.wg_ip}:${port}/${ct.db_name}`;
      } else if (type === "mariadb" && ct.db_user && ct.db_name && vm?.wg_ip && port) {
        entry.connection = `mysql://${ct.db_user}@${vm.wg_ip}:${port}/${ct.db_name}`;
      } else if (type === "redis" && vm?.wg_ip && port) {
        entry.connection = `redis://${vm.wg_ip}:${port}`;
      } else if (type === "s3" && vm?.wg_ip && port) {
        entry.connection = `http://${vm.wg_ip}:${port}`;
      }

      databases.push(entry);

      // Group by type
      if (!byType[type]) byType[type] = [];
      byType[type].push(entry);

      // Count
      summary[type] = (summary[type] ?? 0) + 1;

      // Group by VM
      if (!byVm[vmAlias]) {
        byVm[vmAlias] = {
          wg_ip: vm?.wg_ip ?? "",
          user: vm?.user ?? "ubuntu",
          databases: [],
        };
      }
      byVm[vmAlias].databases.push(entry);
    }
  }

  // ── VM-level system databases ──────────────────────────────────────────
  const vmDatabases: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    const alias = vm.ssh_alias;
    if (!alias) continue;

    vmDatabases[alias] = {
      vm_id: vmId,
      wg_ip: vm.wg_ip ?? null,
      system_dbs: [
        {
          name: "journald",
          type: "binary",
          path: "/var/log/journal/",
          description: "systemd journal logs (binary)",
          queryable: true,
          tool: "journalctl",
        },
        {
          name: "systemd-state",
          type: "binary",
          path: "/var/lib/systemd/",
          description: "systemd persistent state (timers, random-seed)",
          queryable: false,
        },
      ],
    };
  }

  return {
    name: "cloud-data-databases.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/databases",
      total: databases.length,
      summary,
      databases,
      by_type: byType,
      by_vm: byVm,
      vm_system_dbs: vmDatabases,
    },
  };
}

function deriveDnsServices(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;

  // All *.app zones resolve to Caddy (reverse proxy handles port routing)
  // Find Caddy's WG IP from the caddy service entry
  const caddySvc = services["caddy"];
  const caddyVm = caddySvc ? vms[caddySvc.vm] : null;
  const caddyIp = caddyVm?.wg_ip ?? "10.0.0.1";

  // Build service entries: key = dns name without .app suffix, ip = Caddy's WG IP
  const svcEntries: Record<string, { ip: string; desc: string }> = {};

  for (const [svcName, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip) continue;

    // Add entries for each container with a dns field
    for (const container of Object.values(svc.containers ?? {})) {
      const ct = container as any;
      if (ct.dns) {
        const key = ct.dns.endsWith(".app") ? ct.dns.slice(0, -4) : ct.dns;
        svcEntries[key] = { ip: caddyIp, desc: svc.description ?? "" };
      }
    }

    // Also add top-level dns if present and no container dns matched
    if (svc.dns && !Object.values(svc.containers ?? {}).some((ct: any) => ct.dns)) {
      const key = svc.dns.endsWith(".app") ? svc.dns.slice(0, -4) : svc.dns;
      svcEntries[key] = { ip: caddyIp, desc: svc.description ?? "" };
    }
  }

  // S3 storage buckets with dns field → resolve via Caddy like any other .app name
  for (const bucket of (c.storage ?? []) as any[]) {
    if (!bucket.dns) continue;
    const key = bucket.dns.endsWith(".app") ? bucket.dns.slice(0, -4) : bucket.dns;
    svcEntries[key] = { ip: caddyIp, desc: `S3 bucket: ${bucket.name}` };
  }

  // Build VMs map: last octet → ssh_alias
  const vmMap: Record<string, string> = {};
  for (const vm of Object.values(vms)) {
    if (vm.wg_ip && vm.ssh_alias) {
      const lastOctet = vm.wg_ip.split(".").pop()!;
      vmMap[lastOctet] = vm.ssh_alias;
    }
  }

  return {
    name: "cloud-data-dns-services.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/dns-services",
      suffix: "app",
      caddy_ip: caddyIp,
      services: svcEntries,
      vms: vmMap,
    },
  };
}

function deriveCaddy(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const flatRoutes: any[] = c.configs?.caddy?.routes ?? [];

  // Build dns→wg_ip map to resolve any lingering name.app:port → WG_IP:port
  const dnsToIp: Record<string, string> = {};
  for (const [, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip || !svc.dns) continue;
    dnsToIp[svc.dns] = vm.wg_ip;
    for (const ct of Object.values(svc.containers ?? {})) {
      const c = ct as any;
      if (c.dns) dnsToIp[c.dns] = vm.wg_ip;
    }
  }
  const resolveUpstream = (upstream: string | undefined): string | undefined => {
    if (!upstream) return upstream;
    const m = upstream.match(/^([a-z0-9-]+\.app):(\d+)$/);
    if (m && dnsToIp[m[1]]) return `${dnsToIp[m[1]]}:${m[2]}`;
    return upstream;
  };

  // ── L4 routes: derive from gcp-proxy public_ports for mail passthrough ──
  const l4Routes: any[] = [];
  const l4Map: Record<number, string> = {
    993: "IMAPS -- TLS passthrough to maddy",
    465: "SMTPS -- TLS passthrough to maddy",
    587: "SMTP Submission -- TLS passthrough to maddy",
    2993: "IMAPS -- TLS passthrough to stalwart",
    2465: "SMTPS -- TLS passthrough to stalwart",
    2587: "SMTP Submission -- TLS passthrough to stalwart",
    2443: "HTTPS -- TLS passthrough to stalwart (JMAP/webadmin)",
  };
  // Find oci-mail's WG IP (L4 upstream) and gcp-proxy's WG IP (optional listen scope).
  let ociMailIp = "";
  let gcpProxyWgIp = "";
  for (const vm of Object.values(vms) as any[]) {
    if (vm.ssh_alias === "oci-mail") ociMailIp = vm.wg_ip ?? vm.ip;
    if (vm.ssh_alias === "gcp-proxy") gcpProxyWgIp = vm.wg_ip ?? "";
  }
  for (const vm of Object.values(vms) as any[]) {
    if (vm.ssh_alias !== "gcp-proxy") continue;
    for (const pp of vm.public_ports ?? []) {
      if (!l4Map[pp.port]) continue;
      const route: any = {
        port: pp.port,
        upstream: `${ociMailIp}:${pp.port}`,
        comment: l4Map[pp.port],
      };
      // listen_scope = "wg" → Caddy binds only on gcp-proxy's WG IP, not all
      // interfaces. This is the declarative knob for "mail reachable only from
      // WG peers" without dropping the route (Caddy stays the router).
      // Omitted / "public" (default) → route has no `listen` field → Caddy's
      // default = all interfaces = current public behavior.
      if (pp.listen_scope === "wg") {
        if (!gcpProxyWgIp) {
          throw new Error(`listen_scope=wg on port ${pp.port} but gcp-proxy has no wg_ip in config.json`);
        }
        route.listen = `${gcpProxyWgIp}:${pp.port}`;
      }
      l4Routes.push(route);
    }
  }

  // ── Domain routes: services with domain-level proxy ──
  const routes: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy?.domain || proxy.type === "path" || proxy.type === "special" || proxy.streaming || proxy.base_path) continue;
    if (!svc.upstream) continue; // Skip services with no HTTP upstream (e.g. Maddy — SMTP/IMAP only, no web UI)
    const route: any = {
      domain: proxy.domain,
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
      ...(proxy.landing_page ? { landing_page: proxy.landing_page } : {}),
      ...(proxy.tls_skip_verify ? { tls_skip_verify: true } : {}),
      ...(proxy.auth === "none" ? { auth: "none" } : {}),
      comment: svc.description,
    };
    routes.push(route);
  }
  // introspect-proxy is caddy-internal (no external route — consumed by Caddy's forward_auth)

  // ── Path routes: group by parent_domain ──
  const pathGroups: Record<string, { paths: any[]; comment: string; fallback?: string; landing_page?: string }> = {};

  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy || proxy.streaming) continue;
    // Include explicit path type OR services with base_path (implicit path route)
    const isPathRoute = proxy.type === "path" || (proxy.base_path && proxy.domain);
    if (!isPathRoute) continue;
    const pd = proxy.parent_domain ?? proxy.domain;
    if (!pd) continue;
    if (!pathGroups[pd]) pathGroups[pd] = { paths: [], comment: "" };
    pathGroups[pd].paths.push({
      base_path: proxy.base_path,
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
      ...(proxy.public_paths ? { public_paths: proxy.public_paths } : {}),
      comment: svc.description,
    });
  }

  // Also scan flat routes for path-based entries that services don't have
  // (e.g., crawlee dashboard on app hub, windmill, gitea, grafana on app hub,
  //  api/dash redirect, etc.)
  for (const fr of flatRoutes) {
    const domain: string = fr.domain ?? "";
    if (!domain.includes("/")) continue; // Only path-based routes
    const slashIdx = domain.indexOf("/");
    const parentDomain = domain.substring(0, slashIdx);
    const basePath = domain.substring(slashIdx);
    if (!pathGroups[parentDomain]) pathGroups[parentDomain] = { paths: [], comment: "" };
    // Skip if already have this base_path from services
    if (pathGroups[parentDomain].paths.some((p: any) => p.base_path === basePath)) continue;
    const pathEntry: any = {
      base_path: basePath,
      ...(fr.upstream && fr.upstream !== "static" ? { upstream: resolveUpstream(fr.upstream) } : {}),
      ...(fr.public_paths?.length > 0 ? { public_paths: fr.public_paths } : {}),
      ...(fr.upstream === "diegonmarcos.github.io" ? { type: "github_pages", github_path: basePath.replace(/^\//, ""), redirect_bare: true } : {}),
      comment: fr.comment ?? "",
    };
    pathGroups[parentDomain].paths.push(pathEntry);
  }

  // Set group metadata
  const groupMeta: Record<string, { comment: string; fallback?: string; landing_page?: string }> = {
    "app.diegonmarcos.com": { comment: "App hub -- path-based routing", fallback: 'respond "Not Found" 404' },
    "api.diegonmarcos.com": { comment: "API hub -- path-based routing to backend APIs", landing_page: "api" },
    "cloud.diegonmarcos.com": { comment: "Cloud dashboard + spec viewer", landing_page: "cloud" },
  };
  for (const [pd, meta] of Object.entries(groupMeta)) {
    if (pathGroups[pd]) {
      pathGroups[pd].comment = meta.comment;
      if (meta.fallback) pathGroups[pd].fallback = meta.fallback;
      if (meta.landing_page) pathGroups[pd].landing_page = meta.landing_page;
    }
  }

  const pathRoutes = Object.entries(pathGroups).map(([domain, group]) => ({
    parent_domain: domain,
    paths: group.paths,
    comment: group.comment,
    ...(group.fallback ? { fallback: group.fallback } : {}),
    ...(group.landing_page ? { landing_page: group.landing_page } : {}),
  }));

  // ── GitHub Pages proxies: from caddy build.json proxy.github_pages_proxies ──
  const caddyBuildJsonPath = join(CLOUD_ROOT, "a_solutions/bb-sec_caddy/src/build.json");
  const caddyBuildJson = existsSync(caddyBuildJsonPath)
    ? JSON.parse(readFileSync(caddyBuildJsonPath, "utf-8"))
    : {};
  const githubPagesProxies: any[] = (caddyBuildJson.proxy?.github_pages_proxies ?? []).map(
    (entry: any) => ({
      domain: entry.domain,
      github_path: entry.github_path,
      ...(entry.wkd ? { wkd: true } : {}),
      ...(entry.comment ? { comment: entry.comment } : {}),
    }),
  );

  // ── MCP routes: streaming services ──
  const mcpEndpoints: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy?.streaming || !proxy.parent_domain) continue;
    mcpEndpoints.push({
      base_path: proxy.base_path,
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
    });
  }
  const mcpRoutes = mcpEndpoints.length > 0 ? [{
    parent_domain: "mcp.diegonmarcos.com",
    endpoints: mcpEndpoints,
    comment: "MCP -- Streamable HTTP endpoints for Claude Code MCP clients",
    fallback_message: "MCP Hub -- use " + mcpEndpoints.map(e => `${e.base_path}/mcp`).join(", "),
  }] : [];

  // ── Special routes: ntfy (3-tier auth), analytics (matomo+umami), proxy dashboard ──
  const special: Record<string, any> = {};

  // ntfy
  const ntfySvc = services["ntfy"];
  if (ntfySvc) {
    special.ntfy = {
      domain: ntfySvc.domain ?? ntfySvc.proxy?.primary?.domain,
      upstream: ntfySvc.upstream,
      comment: "ntfy notifications -- 3-tier auth: JWT bearer, tk_ bearer, cookie",
    };
  }

  // analytics (matomo + umami)
  const matomoSvc = services["matomo"];
  const umamiSvc = services["umami"];
  if (matomoSvc) {
    special.analytics = {
      domain: matomoSvc.domain ?? matomoSvc.proxy?.primary?.domain,
      comment: "Matomo (public tracking + protected admin) + Umami (path-based)",
      matomo_upstream: matomoSvc.upstream,
      ...(umamiSvc?.upstream ? { umami_upstream: umamiSvc.upstream } : {}),
      public_tracking_paths: ["/matomo.js", "/matomo.php", "/piwik.js", "/piwik.php", "/collect.php", "/api.php", "/track.php", "/js/*"],
      ...(umamiSvc ? { umami_public_paths: ["/umami/script.js", "/umami/api/send"] } : {}),
    };
  }

  // proxy dashboard
  const caddySvc = services["caddy"];
  if (caddySvc) {
    special.proxy_dashboard = {
      domain: caddySvc.domain ?? "proxy.diegonmarcos.com",
      comment: "Infrastructure dashboard (static HTML)",
    };
  }

  // Exclude domains handled by special routes from regular routes/path_routes
  const specialDomains = new Set(Object.values(special).map((s: any) => s.domain).filter(Boolean));
  const filteredRoutes = routes.filter((r: any) => !specialDomains.has(r.domain));
  const filteredPathRoutes = pathRoutes.filter((r: any) => !specialDomains.has(r.parent_domain));

  // Deduplicate subdomain routes by domain (keep first occurrence)
  const seenDomains = new Set<string>();
  const dedupedRoutes = filteredRoutes.filter((r: any) => {
    if (seenDomains.has(r.domain)) return false;
    seenDomains.add(r.domain);
    return true;
  });

  // ── Internal routes: all services with upstream + dns → Caddy HTTP:80 listener ──
  const internalRoutes: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    if (svc.enabled === false) continue;
    if (!svc.upstream || !svc.dns) continue;
    internalRoutes.push({
      service: svc.dns,
      upstream: svc.upstream,
    });
  }
  // VM dashboards: read directly from per-VM build.json (source of truth)
  const hmDir = join(CLOUD_ROOT, "b_infra", "home-manager");
  for (const [, vm] of Object.entries(c.vms ?? {}) as [string, any][]) {
    if (!vm.ssh_alias || !vm.wg_ip) continue;
    try {
      const bjPath = join(hmDir, `nixhm-sudo-${vm.ssh_alias}`, "build.json");
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      if (bj.dashboard?.dns) {
        internalRoutes.push({
          service: bj.dashboard.dns,
          upstream: `${vm.wg_ip}:${bj.dashboard.port ?? 7680}`,
        });
      }
    } catch { /* skip VMs without HM build.json */ }
  }

  // ── S3 bucket routes: external HTTPS proxy via .app short names ──
  const s3Routes: any[] = [];
  for (const bucket of (c.storage ?? []) as any[]) {
    if (!bucket.dns || !bucket.s3_endpoint) continue;
    const s3Host = new URL(bucket.s3_endpoint).host;
    s3Routes.push({
      service: bucket.dns,
      s3_endpoint: bucket.s3_endpoint,
      s3_host: s3Host,
      bucket: bucket.name,
    });
  }

  // ── Redirects: domain → target (permanent redirect, no upstream needed) ──
  const redirects: any[] = [
    { domain: "mail.diegonmarcos.com", target: "https://webmail.diegonmarcos.com{uri}", comment: "mail → webmail redirect" },
  ];

  // ── Auth upstreams: Caddy forward_auth targets (from cloud-data, not hardcoded) ──
  const authUpstreams: Record<string, string> = {};
  const authSvc = services["authelia"];
  if (authSvc?.upstream) authUpstreams.authelia = authSvc.upstream;
  const introspectSvc = services["introspect-proxy"];
  if (introspectSvc?.upstream) authUpstreams.introspect_proxy = introspectSvc.upstream;

  // ── all_app_urls: canonical per-container, per-port .app URL synthesis ──
  // Naming rules (zero heuristics — all declared):
  //   {container}.app                          → HTTPS redirect to first canonical URL
  //   {container}-{protocol}-{port}.app        → canonical per-port entry
  //   {container}-null.app                     → portless workers/sidecars
  // Protocol is read from build.json (containers.<x>.protocol / extra_ports[].protocol / l4_ports[].protocol).
  const allAppUrls: any[] = [];
  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    if (svc.enabled === false) continue;
    const vm = vms[svc.vm];
    if (!vm?.wg_ip) continue;
    const containers = svc.containers ?? {};
    const containerEntries = Object.entries(containers) as [string, any][];
    const isSingle = containerEntries.length === 1;
    for (const [ck, c] of containerEntries) {
      if (!c.container_name) continue;
      if (c.public === false) continue;
      const ports: Array<{ port: number; protocol: string; source: string }> = [];
      const seen = new Set<number>();
      const add = (p: number, proto: string, source: string) => {
        if (seen.has(p)) return;
        seen.add(p);
        ports.push({ port: p, protocol: proto, source });
      };
      if (typeof c.port === "number" && c.protocol) add(c.port, c.protocol, `containers.${ck}.port`);
      for (const ep of (c.extra_ports ?? []) as any[]) {
        if (typeof ep === "object" && typeof ep.port === "number" && ep.protocol) {
          add(ep.port, ep.protocol, `containers.${ck}.extra_ports`);
        }
      }
      if (isSingle) {
        for (const l4 of (svc.proxy?.primary?.l4_ports ?? []) as any[]) {
          if (typeof l4.port === "number" && l4.protocol) add(l4.port, l4.protocol, `proxy.primary.l4_ports`);
        }
      }
      // Redirect target: first canonical URL (or -null for portless)
      const redirectTarget = ports.length > 0
        ? `${c.container_name}-${ports[0].protocol}-${ports[0].port}.app`
        : `${c.container_name}-null.app`;
      // Short alias → HTTPS redirect
      allAppUrls.push({
        kind: "redirect",
        service: `${c.container_name}.app`,
        redirect_to: `https://${redirectTarget}`,
        container: c.container_name,
        container_key: ck,
        svc: svcName,
        vm: svc.vm,
      });
      if (ports.length === 0) {
        allAppUrls.push({
          kind: "portless",
          service: `${c.container_name}-null.app`,
          container: c.container_name,
          container_key: ck,
          svc: svcName,
          vm: svc.vm,
        });
      } else {
        for (const { port, protocol, source } of ports) {
          allAppUrls.push({
            kind: "canonical",
            service: `${c.container_name}-${protocol}-${port}.app`,
            container: c.container_name,
            container_key: ck,
            svc: svcName,
            vm: svc.vm,
            port,
            protocol,
            upstream: `${vm.wg_ip}:${port}`,
            source,
          });
        }
      }
    }
  }

  // ── all_db_urls: {container}-{engine}-{port}.db catalog ─────────────────────
  // 100% data-driven — reads only fields DECLARED in build.json:
  //   - containers.<x>.db_engine   → container IS a DB engine
  //   - containers.<x>.port        → network port of the DB container (may be null)
  //   - containers.<x>.embedded_dbs[] { engine, path?, port? }
  //                                → DB running inside an app container, optionally exposed via `port`
  // Zero regex. Zero port-to-engine guessing. Zero hardcoded tables.
  const allDbUrls: any[] = [];
  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    if (svc.enabled === false) continue;
    const vm = vms[svc.vm];
    if (!vm?.wg_ip) continue;
    for (const [ck, c] of Object.entries(svc.containers ?? {}) as [string, any][]) {
      if (!c.container_name) continue;
      if (c.public === false) continue;
      const common = { container: c.container_name, container_key: ck, svc: svcName, vm: svc.vm };

      // A) Declared DB container
      if (c.db_engine) {
        const engine = c.db_engine;
        if (typeof c.port === "number") {
          allDbUrls.push({
            kind: "container",
            service: `${c.container_name}-${engine}-${c.port}.db`,
            ...common, engine, port: c.port,
            upstream: `${vm.wg_ip}:${c.port}`,
          });
        } else {
          allDbUrls.push({
            kind: "container",
            service: `${c.container_name}-${engine}-null.db`,
            ...common, engine, port: null,
            note: "DB container on docker-internal network only (no host port)",
          });
        }
      }

      // B) Embedded DBs — optionally with a port (covers "bundled" case like matomo-hybrid)
      for (const edb of (c.embedded_dbs ?? []) as any[]) {
        if (!edb?.engine) continue;
        if (typeof edb.port === "number") {
          allDbUrls.push({
            kind: "bundled",
            service: `${c.container_name}-${edb.engine}-${edb.port}.db`,
            ...common, engine: edb.engine, port: edb.port,
            upstream: `${vm.wg_ip}:${edb.port}`,
            ...(edb.path ? { path: edb.path } : {}),
          });
        } else {
          allDbUrls.push({
            kind: "embedded",
            service: `${c.container_name}-${edb.engine}-null.db`,
            ...common, engine: edb.engine, port: null,
            ...(edb.path ? { path: edb.path } : {}),
          });
        }
      }
    }
  }

  // ── caddy_config passthrough: global, snippets, auth, wkd, mta_sts, etc. ──
  // Source: services.caddy.caddy_config (via entry.extra in consolidated.ts)
  // All hardcoded flake values now live here → 100% data-driven Caddyfile.
  const caddyCfg: any = services["caddy"]?.caddy_config ?? {};

  // ── Taxonomy views (derived from functional keys — for humans/debugging) ──
  const hubDomains = new Set(["mcp.diegonmarcos.com", "api.diegonmarcos.com", "app.diegonmarcos.com"]);
  const publicAMcp: any[] = [];
  const publicBApis: any[] = [];
  const publicCAppPaths: any[] = [];
  const publicDOthers: any[] = [];

  const makeRow = (host: string, path: string | null, upstream: string, kind: string, tls: string, service: string | null, notes: string | null) =>
    ({ host, path, upstream, kind, tls, zone: "com", service, notes });

  for (const r of dedupedRoutes) {
    const row = makeRow(r.domain, null, r.upstream ?? "?", "reverse_proxy", "public", null, r.comment ?? null);
    if (r.domain === "mcp.diegonmarcos.com") publicAMcp.push({ ...row, kind: "hub_root" });
    else if (r.domain === "api.diegonmarcos.com") publicBApis.push({ ...row, kind: "hub_root" });
    else if (r.domain === "app.diegonmarcos.com") publicCAppPaths.push({ ...row, kind: "hub_root" });
    else publicDOthers.push(row);
  }
  for (const group of filteredPathRoutes) {
    for (const p of group.paths ?? []) {
      const row = makeRow(group.parent_domain, p.base_path, p.upstream ?? "?", "reverse_proxy", "public", null, p.comment ?? null);
      if (group.parent_domain === "mcp.diegonmarcos.com") publicAMcp.push(row);
      else if (group.parent_domain === "api.diegonmarcos.com") publicBApis.push(row);
      else if (group.parent_domain === "app.diegonmarcos.com") publicCAppPaths.push(row);
      else publicDOthers.push(row);
    }
  }
  for (const mcpGroup of mcpRoutes) {
    for (const ep of mcpGroup.endpoints ?? []) {
      publicAMcp.push(makeRow(mcpGroup.parent_domain, ep.base_path, ep.upstream, "reverse_proxy", "public", null, ep.comment ?? null));
    }
  }
  for (const g of githubPagesProxies) {
    publicDOthers.push(makeRow(g.domain, null, "https://diegonmarcos.github.io", "reverse_proxy", "public", null, `github_path=${g.github_path ?? "?"}`));
  }
  for (const red of redirects) {
    publicDOthers.push(makeRow(red.domain, null, red.target, "redirect", "public", null, red.comment ?? null));
  }

  const privateA0AppShort = internalRoutes.map((r: any) => makeRow(r.service, null, r.upstream, "reverse_proxy", "internal", null, null));
  const privateA1AppCanonical = (allAppUrls.filter((u: any) => u.kind === "canonical") as any[]).map(u =>
    makeRow(u.service, null, u.upstream, "reverse_proxy", "on_demand", u.svc, (u.container.includes("_") ? "underscore → TLS broken" : null)));
  const privateA2AppPortless = (allAppUrls.filter((u: any) => u.kind === "portless") as any[]).map(u =>
    ({ host: u.service, path: null, upstream: "204", kind: "portless", tls: "on_demand", zone: "app", service: u.svc, notes: (u.container.includes("_") ? "underscore → TLS broken" : null) }));

  const privateB0Db = allDbUrls.map((u: any) =>
    ({ host: u.service, path: u.path ?? null, upstream: u.upstream ?? "embedded", kind: "catalog", tls: "on_demand", zone: "db", service: u.svc,
       notes: `engine=${u.engine}${u.vm ? ` vm=${u.vm}` : ""}${(u.container ?? "").includes("_") ? " underscore → TLS broken" : ""}${u.note ? ` ${u.note}` : ""}` }));

  const privateB1S3 = s3Routes.map((r: any) =>
    ({ host: r.service, path: null, upstream: r.s3_endpoint, kind: "reverse_proxy", tls: "internal", zone: "app", service: null, notes: `OCI bucket: ${r.bucket}` }));

  const l4Listeners = l4Routes.map((r: any) =>
    ({ host: `:${r.port}`, path: null, upstream: r.upstream, kind: "l4_forward", tls: "none", zone: "l4", service: null, notes: r.comment ?? null }));

  const others: any[] = [
    { host: "<global>",       path: null, upstream: caddyCfg.global?.admin_bind ?? "?", kind: "directive",    tls: "none",   zone: "global", service: "caddy", notes: "admin bind" },
    { host: "<global>",       path: null, upstream: caddyCfg.global?.auto_https ?? "?", kind: "directive",    tls: "none",   zone: "global", service: "caddy", notes: "auto_https" },
    { host: "<global>",       path: null, upstream: caddyCfg.on_demand_tls?.ask_url ?? "?", kind: "directive", tls: "none",  zone: "global", service: "caddy", notes: "on_demand_tls ask" },
    { host: caddyCfg.on_demand_tls?.ask_bind ?? "?", path: null, upstream: "200", kind: "ask_endpoint", tls: "none", zone: "helper", service: "caddy", notes: "on-demand TLS approver" },
    { host: caddyCfg.catch_all?.domain ?? "?", path: null, upstream: caddyCfg.catch_all?.page ?? "?", kind: "catch_all", tls: "public", zone: "com", service: "caddy", notes: "catch-all" },
    { host: caddyCfg.mta_sts?.domain ?? "?", path: caddyCfg.mta_sts?.policy_path ?? "?", upstream: "(inline)", kind: "static", tls: "public", zone: "com", service: "caddy", notes: "MTA-STS policy" },
  ];
  for (const wkdDomain of (caddyCfg.wkd?.domains ?? []) as string[]) {
    others.push({ host: wkdDomain, path: caddyCfg.wkd.path, upstream: `/srv/wkd/hu/${caddyCfg.wkd.hash}`, kind: "file_server", tls: "public", zone: "com", service: "caddy", notes: "PGP WKD" });
  }

  return {
    name: "build-caddy.json",
    data: {
      _meta: {
        description: "Caddy route definitions -- consumed by flake.nix to generate Caddyfile",
        format_version: 3,
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/caddy-routes",

      // ── Functional keys (consumed by flake.nix renderers) ──
      global:           caddyCfg.global           ?? {},
      on_demand_tls:    caddyCfg.on_demand_tls    ?? {},
      security_snippets:caddyCfg.security_snippets?? {},
      auth:             caddyCfg.auth             ?? {},
      error_handler:    caddyCfg.error_handler    ?? {},
      static_files:     caddyCfg.static_files     ?? [],
      wkd:              caddyCfg.wkd              ?? {},
      mta_sts:          caddyCfg.mta_sts          ?? {},
      catch_all:        caddyCfg.catch_all        ?? {},
      messages:         caddyCfg.messages         ?? {},
      l4_routes:        l4Routes,
      redirects,
      routes:           dedupedRoutes,
      path_routes:      filteredPathRoutes,
      github_pages_proxies: githubPagesProxies,
      mcp_routes:       mcpRoutes,
      special,
      internal_routes:  internalRoutes,
      s3_routes:        s3Routes,
      auth_upstreams:   authUpstreams,
      all_app_urls:     allAppUrls,
      all_db_urls:      allDbUrls,

      // ── Taxonomy views (derived from functional keys — humans/docs only) ──
      public_A_mcp:             publicAMcp,
      public_B_apis:            publicBApis,
      public_C_app_paths:       publicCAppPaths,
      public_D_others:          publicDOthers,
      private_A0_app_short:     privateA0AppShort,
      private_A1_app_canonical: privateA1AppCanonical,
      private_A2_app_portless:  privateA2AppPortless,
      private_B0_db:            privateB0Db,
      private_B1_s3:            privateB1S3,
      l4_listeners:             l4Listeners,
      others,
    },
  };
}

function deriveAutheliaAcl(c: any): DerivedFile {
  const acl: any[] = c.configs?.authelia?.acl ?? [];

  // Enrich each rule with a `service` field if missing (backward compat)
  const rules = acl.map(rule => ({
    ...rule,
    service: rule.service ?? "_default",
  }));

  return {
    name: "cloud-data-authelia-acl.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/authelia-acl",
      rules,
    },
  };
}

// ── Per-container derived configs (pattern: build-{container}.json) ──
// Each service gets ONE consolidated JSON slice containing only what its
// flake.nix actually reads. Replaces the old pattern of symlinking every
// cloud-data-*.json into src/.
function deriveAuthelia(c: any): DerivedFile {
  const serviceConnections = deriveServiceConnections(c).data as any;
  const aclData = deriveAutheliaAcl(c).data as any;
  const container = c.services?.authelia?.containers?.app ?? {};

  return {
    name: "build-authelia.json",
    data: {
      _meta: {
        description: "Authelia consolidated config -- consumed by bb-sec_authelia/src/flake.nix",
        format_version: 1,
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/authelia",
      container,
      service: "authelia",
      services: serviceConnections.services ?? {},
      acl: { rules: aclData.rules ?? [] },
    },
  };
}

function deriveRedis(c: any): DerivedFile {
  const serviceConnections = deriveServiceConnections(c).data as any;
  const container = c.services?.redis?.containers?.app ?? {};

  return {
    name: "build-redis.json",
    data: {
      _meta: {
        description: "Redis consolidated config -- consumed by ca-dat_redis/src/flake.nix",
        format_version: 1,
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/redis",
      container,
      service: "redis",
      services: serviceConnections.services ?? {},
    },
  };
}

/** Generic: emit one build-{container}.json per container in the topology.
 *  Skips containers that already have a specialized derive function
 *  (caddy, authelia, redis — those add extra data like routes or acl).
 */
function deriveContainerConfigs(c: any): DerivedFile[] {
  const serviceConnections = deriveServiceConnections(c).data as any;
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const SPECIAL_CASES = new Set(["caddy", "authelia", "redis"]);
  const files: DerivedFile[] = [];

  for (const [svcName, svc] of Object.entries(services)) {
    const containers = (svc as any).containers ?? {};
    for (const [role, ct] of Object.entries(containers) as [string, any][]) {
      const containerName = ct.container_name || svcName;
      if (SPECIAL_CASES.has(containerName)) continue;

      const vmEntry = vms[(svc as any).vm];
      files.push({
        name: `build-${containerName}.json`,
        data: {
          _meta: {
            description: `${containerName} container config (service=${svcName}, role=${role})`,
            format_version: 1,
          },
          _generated: now(),
          _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/container-configs",
          container: ct,
          service: svcName,
          role,
          vm: vmEntry?.ssh_alias ?? (svc as any).vm,
          services: serviceConnections.services ?? {},
        },
      });
    }
  }
  return files;
}

function deriveHomeManager(c: any): DerivedFile {
  const hmData = c._home_manager ?? {};
  const vms = hmData.vms ?? {};
  const sshConfig = hmData.ssh_config ?? [];

  // Enrich wireguard peers with wg_public_key from HM build.json + VM entries
  const wg = { ...(c.native?.wireguard ?? {}) };

  // Read wg_public_key from each VM's HM build.json (authoritative source for per-VM keys)
  const hmKeysByAlias = new Map<string, string>();
  const HM_DIR = join(CLOUD_ROOT, "b_infra", "home-manager");
  for (const vmAlias of ["gcp-proxy", "oci-mail", "oci-analytics", "oci-apps", "gcp-t4"]) {
    try {
      const buildJsonPath = join(HM_DIR, vmAlias, "build.json");
      if (existsSync(buildJsonPath)) {
        const buildJson = JSON.parse(readFileSync(buildJsonPath, "utf-8"));
        if (buildJson.wg_public_key) hmKeysByAlias.set(vmAlias, buildJson.wg_public_key);
      }
    } catch { /* skip unreadable */ }
  }

  // Fallback: preserve existing keys from cloud-data-home-manager.json
  // (critical when running on VMs where HM build.json isn't accessible)
  const existingHmPath = join(CLOUD_DATA_DIR, "cloud-data-home-manager.json");
  const existingKeysByName = new Map<string, string>();
  if (existsSync(existingHmPath)) {
    try {
      const existing = JSON.parse(readFileSync(existingHmPath, "utf-8"));
      for (const peer of (existing.wireguard?.peers ?? [])) {
        if (peer.name && peer.wg_public_key) existingKeysByName.set(peer.name, peer.wg_public_key);
      }
    } catch { /* skip */ }
  }

  if (Array.isArray(wg.peers) && c.vms) {
    const vmsByAlias = new Map<string, any>();
    for (const vm of Object.values(c.vms) as any[]) {
      if (vm.ssh_alias) vmsByAlias.set(vm.ssh_alias, vm);
    }
    wg.peers = wg.peers.map((peer: any) => {
      const vm = vmsByAlias.get(peer.name);
      const enriched: any = { ...peer };
      // Priority: HM build.json > config.json VM entry > existing cloud-data > peer value
      const hmKey = hmKeysByAlias.get(peer.name);
      const existingKey = existingKeysByName.get(peer.name);
      if (hmKey) enriched.wg_public_key = hmKey;
      else if (vm?.wg_public_key && !peer.wg_public_key) enriched.wg_public_key = vm.wg_public_key;
      else if (existingKey && !enriched.wg_public_key) enriched.wg_public_key = existingKey;
      if (vm?.wg_port && !peer.wg_port) enriched.wg_port = vm.wg_port;
      if (vm?.ip && !peer.public_ip) enriched.public_ip = vm.ip;
      if (!enriched.public_ip && peer.endpoint?.includes(":")) {
        enriched.public_ip = peer.endpoint.split(":")[0];
      }
      return enriched;
    });
  }

  // Validate: warn if any peer still has null wg_public_key
  if (Array.isArray(wg.peers)) {
    for (const peer of wg.peers) {
      if (!peer.wg_public_key) {
        console.warn(`WARNING: wireguard peer "${peer.name}" has no wg_public_key — WG mesh will be broken for this peer`);
      }
    }
  }
  // Validate clients too
  if (wg.clients) {
    for (const [name, client] of Object.entries(wg.clients) as [string, any][]) {
      if (!client.wg_public_key) {
        console.warn(`WARNING: wireguard client "${name}" has no wg_public_key — WG mesh will be broken for this client`);
      }
    }
  }

  return {
    name: "cloud-data-home-manager.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/home-manager",
      owner: c.owner ?? {},
      home_manager: c.home_manager ?? { state_version: "24.11" },
      vms,
      wireguard: wg,
      dns: c.native?.dns ?? {},
      docker: c.native?.docker ?? {},
      monitoring: c.native?.monitoring ?? {},
      ssh_config: sshConfig,
    },
  };
}

function deriveGhaConfig(c: any): DerivedFile {
  const ghaData = c._gha ?? {};
  // Enrich GHA VMs with WG IPs from main VM data
  const vms: Record<string, any> = {};
  for (const [vmAlias, ghaVm] of Object.entries(ghaData.vms ?? {}) as [string, any][]) {
    const mainVm = Object.values(c.vms ?? {}).find((v: any) => v.ssh_alias === vmAlias) as any;
    // Hub (gcp-proxy) uses public IP for GHA SSH (Docker can't route to WG hub IP)
    const isHub = mainVm?.wg_role === "hub";
    const enriched = { ...ghaVm, wg_ip: mainVm?.wg_ip ?? null, user: ghaVm.user ?? mainVm?.user ?? null };
    if (isHub && mainVm?.ip) {
      enriched.host = mainVm.ip;
      delete enriched.wg_ip;
    }
    vms[vmAlias] = enriched;
  }

  // 2026-04-27 renamed: cloud-data-gha-config.json → build-gha.json.
  // Reason: aligns with the per-service build-{name}.json convention — every
  // ship-system config is a build-*.json. Consumers (.github/workflows/ship.yml,
  // 1_workflows/src/scripts/cloud-ship-orchestrate-{ghcr,vm}.sh) prefer this
  // path; the legacy name lingers as a fallback during rollout.
  return {
    name: "build-gha.json",
    data: {
      _warning: "AUTO-GENERATED by cloud-data-config-derive.ts — DO NOT EDIT.",
      _meta: {
        description: "GHA ship-system config (vms + services dispatch matrix)",
        format_version: 1,
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/gha-config",
      vms,
      services: ghaData.services ?? {},
    },
  };
}

function deriveWireguardPeers(c: any): DerivedFile {
  const wg = c.native?.wireguard ?? {};
  const vms = c.vms as Record<string, any>;

  // Build mesh_peers from peers array enriched with VM data
  const meshPeers: any[] = [];
  for (const peer of (wg.peers ?? [])) {
    // Find VM by ssh_alias
    let vmUser = "ubuntu";
    let vmId = "";
    for (const [id, vm] of Object.entries(vms) as [string, any][]) {
      if (vm.ssh_alias === peer.name) {
        vmUser = vm.user;
        vmId = id;
        break;
      }
    }
    meshPeers.push({
      vm_id: vmId,
      name: peer.name,
      wg_ip: peer.wg_ip,
      public_ip: peer.endpoint?.replace(/:.*$/, "") ?? peer.public_ip ?? "",
      user: vmUser,
    });
  }

  // Add client peers (Surface, Termux, etc.) from wg.clients
  for (const [name, client] of Object.entries(wg.clients ?? {}) as [string, any][]) {
    meshPeers.push({
      vm_id: "",
      name,
      wg_ip: client.wg_ip,
      public_ip: "dynamic",
      user: "",
      role: client.role || "client",
    });
  }

  // Build peers list as vm_ids
  const peerVmIds = meshPeers
    .filter(p => p.wg_ip !== wg.peers?.find((wp: any) => wp.role === "hub")?.wg_ip)
    .map(p => p.vm_id)
    .filter(Boolean);

  return {
    name: "cloud-data-wireguard-peers.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/wireguard-peers",
      hub: wg.hub ?? null,
      peers: peerVmIds,
      mesh_peers: meshPeers,
    },
  };
}

function deriveFirewallRules(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  // Per-VM ingress arrays (currently empty as rules come from terraform)
  const vmFirewalls: Record<string, { ingress: any[] }> = {};
  for (const [vmId, vm] of Object.entries(vms)) {
    const alias = vm.ssh_alias;
    if (alias) {
      vmFirewalls[alias] = { ingress: [] };
    }
  }

  return {
    name: "cloud-data-firewall-rules.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/firewall-rules",
      vms: vmFirewalls,
    },
  };
}

function deriveMonitoringTargets(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;

  const endpointChecks: any[] = [];
  const dnsChecks: any[] = [];
  const tlsChecks: any[] = [];

  for (const [svcName, svc] of Object.entries(services)) {
    const mon = svc.monitoring;
    if (!mon) continue;
    if (mon.endpoint_check && svc.domain) {
      // Defence-in-depth: even after the parser fix, if anything upstream
      // ever puts a non-URL value into svc.health.path the URL would be
      // garbage. Validate that the path is a real URL path (starts with "/")
      // and fall back to "/" otherwise — keep the pipeline declarative,
      // never emit a corrupted URL.
      const rawPath = svc.health?.path;
      const path = (typeof rawPath === "string" && rawPath.startsWith("/")) ? rawPath : "/";
      endpointChecks.push({
        service: svcName,
        url: `https://${svc.domain}${path}`,
      });
    }
    if (mon.dns_check && svc.domain) {
      dnsChecks.push({ service: svcName, domain: svc.domain });
    }
    if (mon.tls_check && svc.domain) {
      tlsChecks.push({ service: svcName, domain: svc.domain });
    }
  }

  const vmList = Object.values(vms)
    .filter((vm: any) => vm.wg_ip && vm.ssh_alias)
    .map((vm: any) => ({
      ip: vm.wg_ip,
      name: vm.ssh_alias,
      user: vm.user,
    }));

  return {
    name: "cloud-data-monitoring-targets.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/monitoring-targets",
      endpoint_checks: endpointChecks,
      dns_checks: dnsChecks,
      tls_checks: tlsChecks,
      vms: vmList,
    },
  };
}

// build-reports.json — single derived file consumed by every reports/ rust
// crate (cloud-health-full-daily, cloud-url-health-report, mail-health-full,
// sec-network) AND the bash collector (reports-logs/build.sh).
//
// Pattern: cloud-data-*.json files are DEPRECATED (routed to z_archive by
// targetDirFor()). Reports must source from this single derived file
// instead. Removed services (no active a_solutions/<svc>/build.json) drop
// out automatically because the consolidated input already excludes them
// — no more ghost entries like windmill / postlite / quant-lab-* showing
// up in monitoring URLs months after deletion.
//
// Shape mirrors the legacy cloud-data-monitoring-targets.json plus extras
// (collector ssh_opts, evidence output_dir) so the migration is a one-line
// path swap on the consumer side, not a schema change.
function deriveBuildReports(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;

  const endpointChecks: any[] = [];
  const dnsChecks: any[] = [];
  const tlsChecks: any[] = [];

  for (const [svcName, svc] of Object.entries(services)) {
    const mon = svc.monitoring;
    if (!mon) continue;
    if (mon.endpoint_check && svc.domain) {
      const rawPath = svc.health?.path;
      const path = (typeof rawPath === "string" && rawPath.startsWith("/")) ? rawPath : "/";
      endpointChecks.push({
        service: svcName,
        url: `https://${svc.domain}${path}`,
      });
    }
    if (mon.dns_check && svc.domain) {
      dnsChecks.push({ service: svcName, domain: svc.domain });
    }
    if (mon.tls_check && svc.domain) {
      tlsChecks.push({ service: svcName, domain: svc.domain });
    }
  }

  const vmList = Object.values(vms)
    .filter((vm: any) => vm.wg_ip && vm.ssh_alias)
    .map((vm: any) => ({
      ip: vm.wg_ip,
      name: vm.ssh_alias,
      user: vm.user,
    }));

  return {
    name: "build-reports.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/build-reports",
      _replaces: ["cloud-data-monitoring-targets.json"],
      endpoint_checks: endpointChecks,
      dns_checks: dnsChecks,
      tls_checks: tlsChecks,
      vms: vmList,
    },
  };
}

function deriveBackupTargets(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;

  // Build VM alias lookup
  const vmIdToAlias: Record<string, string> = {};
  const vmById: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    if (vm.ssh_alias) vmIdToAlias[vmId] = vm.ssh_alias;
    vmById[vmId] = vm;
  }

  const targets: any[] = [];
  const byVm: Record<string, { wg_ip: string; user: string; databases: any[]; volumes: string[] }> = {};

  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    if (!svc.backup?.enabled) continue;

    const vmAlias = vmIdToAlias[svc.vm] ?? svc.vm;
    const vm = vmById[svc.vm];

    // Scan containers for DB metadata (100% declared — no image regex)
    const databases: any[] = [];
    if (svc.containers) {
      for (const [ctKey, ct] of Object.entries(svc.containers) as [string, any][]) {
        const hasDbFields = ct.db_engine || ct.embedded_dbs?.length
          || ct.db_user || ct.db_name || ct.db_path || ct.dump_cmd;
        if (!hasDbFields) continue;

        // Dump-type resolution: declared db_engine → embedded_dbs[0] → legacy db_path → dump_cmd
        let type: string;
        if (ct.db_engine) type = ct.db_engine;
        else if (Array.isArray(ct.embedded_dbs) && ct.embedded_dbs[0]?.engine) type = ct.embedded_dbs[0].engine;
        else if (ct.db_path) type = "sqlite";
        else type = "custom";

        // Path resolution: prefer embedded_dbs[0].path when present (new schema)
        const embPath = Array.isArray(ct.embedded_dbs) ? ct.embedded_dbs[0]?.path : undefined;
        const path = ct.db_path ?? embPath;

        databases.push({
          service: svcName,
          container: ct.container_name,
          container_key: ctKey,
          type,
          ...(ct.db_user ? { user: ct.db_user } : {}),
          ...(ct.db_name ? { db: ct.db_name } : {}),
          ...(path ? { path } : {}),
          ...(ct.dump_cmd ? { dump_cmd: ct.dump_cmd } : {}),
        });
      }
    }

    targets.push({
      service: svcName,
      vm: svc.vm,
      vm_alias: vmAlias,
      volumes: svc.backup.volumes ?? [],
      databases,
    });

    // Group by VM
    if (!byVm[vmAlias]) {
      byVm[vmAlias] = {
        wg_ip: vm?.wg_ip ?? "",
        user: vm?.user ?? "ubuntu",
        databases: [],
        volumes: [],
      };
    }
    byVm[vmAlias].databases.push(...databases);
    byVm[vmAlias].volumes.push(...(svc.backup.volumes ?? []));
  }

  return {
    name: "cloud-data-backup-targets.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/backup-targets",
      targets,
      by_vm: byVm,
    },
  };
}

function deriveContainerResources(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  const svcResources: Record<string, any> = {};
  for (const [svcName, svc] of Object.entries(services)) {
    const alias = vmIdToAlias[svc.vm] ?? svc.vm;
    const vm = vms[svc.vm];
    const containerNames = svc.container_names ?? [];

    // Check if any container has resource limits
    let resources: any = null;
    for (const ct of Object.values(svc.containers ?? {})) {
      if ((ct as any).resources) {
        resources = (ct as any).resources;
        break;
      }
    }

    svcResources[svcName] = {
      vm: alias,
      vm_ram_gb: vm?.specs?.ram_gb ?? null,
      vm_cpu: vm?.specs?.cpu ?? null,
      containers: containerNames,
      resources,
    };
  }

  return {
    name: "cloud-data-container-resources.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/container-resources",
      services: svcResources,
    },
  };
}

function deriveLogRouting(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  const vmLogs: Record<string, any[]> = {};
  for (const [svcName, svc] of Object.entries(services)) {
    const alias = vmIdToAlias[svc.vm] ?? svc.vm;
    if (!vmLogs[alias]) vmLogs[alias] = [];

    for (const ct of Object.values(svc.containers ?? {})) {
      const ctObj = ct as any;
      vmLogs[alias].push({
        container: ctObj.container_name,
        service: svcName,
        log_level: "info", // Default, can be overridden via container spec
      });
    }
  }

  return {
    name: "cloud-data-log-routing.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/log-routing",
      vms: vmLogs,
    },
  };
}

function deriveCloudflareDns(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const domain = c.owner?.domain ?? "diegonmarcos.com";

  // Derive DNS records from services with domains
  const records: any[] = [];
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.domain && svc.domain !== "\u2014" && !svc.domain.endsWith(".internal")) {
      records.push({
        name: svc.domain,
        type: "CNAME",
        content: domain,
        proxied: true,
        service: svcName,
      });
    }
  }

  // Also check dns.cloudflare from consolidated if present
  if (c.dns?.cloudflare?.length > 0) {
    // Use pre-parsed cloudflare records
    return {
      name: "cloud-data-cloudflare-dns.json",
      data: {
        _generated: now(),
        _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/cloudflare-dns",
        zone: domain,
        records: c.dns.cloudflare,
      },
    };
  }

  return {
    name: "cloud-data-cloudflare-dns.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/cloudflare-dns",
      zone: domain,
      records,
    },
  };
}

function deriveMatomoSites(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const sites: any[] = [];

  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.domain && svc.domain !== "\u2014") {
      sites.push({
        name: svc.description ?? svcName,
        url: `https://${svc.domain}`,
        service: svcName,
      });
    }
  }

  return {
    name: "cloud-data-matomo-sites.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/matomo-sites",
      sites,
    },
  };
}

function deriveNtfyAcl(c: any): DerivedFile {
  const ntfyConfig = c.configs?.ntfy;
  const topicList: any[] = ntfyConfig?.topics ?? [];

  // Build topics object keyed by name, grouped by category
  const topics: Record<string, any> = {};
  const categories: Record<string, string[]> = {};

  for (const t of topicList) {
    topics[t.name] = {
      category: t.category,
      desc: t.desc,
      publishers: t.publishers,
    };
    const cat = t.category;
    if (!categories[cat]) categories[cat] = [];
    categories[cat].push(t.name);
  }

  return {
    name: "cloud-data-ntfy-acl.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/ntfy-acl",
      base_url: `https://${c.services?.ntfy?.dns?.domain ?? "rss.diegonmarcos.com"}`,
      auth_default_access: ntfyConfig?.auth_default_access ?? "read-write",
      users: ntfyConfig?.users ?? [],
      all_topics: topicList.map((t: any) => t.name).join(","),
      categories,
      topics,
    },
  };
}

// Per-VM container manifests for docker-pull-up.sh
// Produces one cloud-data-containers-{alias}.json per VM
function deriveVmContainerManifests(c: any): DerivedFile[] {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const gha = c._gha ?? {};
  const ghaServices = gha.services ?? {};
  const vmIdToAlias = buildVmIdToAlias(vms);

  const files: DerivedFile[] = [];

  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    const alias = vm.ssh_alias;
    if (!alias) continue;

    const vmServices: any[] = [];
    for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
      if (svc.vm !== vmId) continue;

      // Collect all images from containers
      const images: string[] = [];
      for (const ct of Object.values(svc.containers ?? {})) {
        const img = (ct as any).image;
        if (img && img !== "" && !img.endsWith(":local")) {
          images.push(img);
        }
      }

      // Get has_docker from GHA config
      const ghaEntry = ghaServices[svcName] ?? {};
      const hasDockerBuild = ghaEntry.has_docker ?? false;
      const dir = ghaEntry.dir ?? svc.folder ?? svcName;

      vmServices.push({
        name: svcName,
        dir,
        compose_path: `/opt/containers/${svcName}`,
        images,
        has_docker_build: hasDockerBuild,
      });
    }

    if (vmServices.length === 0) continue;

    files.push({
      name: `cloud-data-containers-${alias}.json`,
      data: {
        _generated: now(),
        _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/vm-container-manifests",
        vm: alias,
        vm_id: vmId,
        services: vmServices,
      },
    });
  }

  return files;
}

function deriveTopology(c: any): DerivedFile {
  // Backward compat: produce the old topology format from consolidated data
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  // Build old-style VM entries (keyed by vmId)
  const oldVms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    // Build containers list from services assigned to this VM
    const vmContainers: string[] = [];
    const vmPorts: string[] = [];
    const vmNetworks: string[] = [];
    for (const [, svc] of Object.entries(services) as [string, any][]) {
      if (svc.vm !== vmId) continue;
      vmContainers.push(...(svc.container_names ?? []));
      vmPorts.push(...(svc.compose?.ports ?? []));
      vmNetworks.push(...(svc.compose?.networks ?? []));
    }
    // Deduplicate networks
    const uniqueNetworks = [...new Set(vmNetworks)];

    oldVms[vmId] = {
      ip: vm.ip,
      wg_ip: vm.wg_ip,
      user: vm.user,
      method: vm.method,
      ssh_alias: vm.ssh_alias,
      ...(vm.gcloud_instance ? { gcloud_instance: vm.gcloud_instance, gcloud_zone: vm.gcloud_zone } : {}),
      ...(vm.instance_id ? { instance_id: vm.instance_id } : {}),
      description: vm.description,
      ...(vm.provider ? { provider: vm.provider, gpu: vm.specs?.gpu } : {}),
      gha: vm.gha,
      ...(vm.idle_shutdown ? { idle_shutdown: vm.idle_shutdown } : {}),
      containers: vmContainers,
      ports: vmPorts,
      networks: uniqueNetworks,
      specs: {
        cpu: vm.specs?.cpu ?? null,
        ram_gb: vm.specs?.ram_gb ?? null,
        disk_gb: vm.specs?.disk_gb ?? null,
        ...(vm.specs?.shape ? { shape: vm.specs.shape } : {}),
        ...(vm.specs?.machine_type ? { machine_type: vm.specs.machine_type } : {}),
      },
    };
  }

  // Build old-style services map
  const oldServices: Record<string, any> = {};
  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    oldServices[svcName] = {
      category: svc.category,
      vm: svc.vm,
      folder: svc.folder,
      description: svc.description,
      ...(svc.domain ? { domain: svc.domain } : {}),
      ...(svc.port != null ? { port: svc.port } : {}),
      ...(svc.dns ? { dns: svc.dns } : {}),
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
      containers: svc.containers,
      container_names: svc.container_names,
      all_ports: svc.all_ports,
      all_dns: svc.all_dns,
      compose: svc.compose,
      ...(svc.proxy ? { proxy: svc.proxy } : {}),
      ...(svc.declared_ports ? { declared_ports: svc.declared_ports } : {}),
      ...(svc.health ? { health: svc.health } : {}),
      ...(svc.monitoring ? { monitoring: svc.monitoring } : {}),
      ...(svc.backup ? { backup: svc.backup } : {}),
      ...(svc.notifications ? { notifications: svc.notifications } : {}),
      ...(svc.fallback_vm ? { fallback_vm: svc.fallback_vm } : {}),
      ...(svc.flake ? { flake: svc.flake } : {}),
      ...(svc.extra ? { extra: svc.extra } : {}),
    };
  }

  return {
    name: "cloud-data-topology.json",
    data: {
      owner: c.owner ?? {},
      ssh_key: c.ssh_key,
      remote_base: c.remote_base,
      vms: oldVms,
      vpss: c.vpss ?? {},
      storage: c.storage ?? [],
      firewalls: c.firewalls ?? {},
      os_firewalls: c.firewalls?.os ?? {},
      os_firewall_global: c.firewalls?.global ?? {},
      wireguard: c.native?.wireguard ?? {},
      dns: c.dns ?? {},
      services: oldServices,
      native: {
        wireguard: c.native?.wireguard ?? {},
        dns: c.native?.dns ?? {},
        docker: c.native?.docker ?? {},
        monitoring: c.native?.monitoring ?? {},
      },
      deps: c.deps ?? {},
      engine_folder: c.engine_folder ?? "bc-obs_c3-infra-mcp",
    },
  };
}

function deriveConfigs(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;

  // Build services array sorted by name, with vm, category, etc.
  const svcList: any[] = [];
  for (const [svcName, svc] of Object.entries(services)) {
    svcList.push({
      name: svcName,
      category: svc.category,
      vm: svc.vm,
      description: svc.description,
      domain: svc.domain ?? "\u2014",
      ports: svc.compose?.ports ?? [],
      networks: svc.compose?.networks ?? [],
      containers: svc.container_names ?? [],
    });
  }
  svcList.sort((a, b) => a.name.localeCompare(b.name));

  // Build infra and apps groupings
  const infraServices = svcList.filter(s =>
    ["sec", "cloud", "tools", "data"].includes(s.category)
  );
  const appServices = svcList.filter(s =>
    ["app", "mic", "fin", "agi"].includes(s.category)
  );

  return {
    name: "cloud-data-configs.json",
    data: {
      _meta: {
        generated_by: "cloud-data-config-derive.ts",
        api_route: "GET /c3-api/cloud-data/configs",
        source: "_cloud-data-consolidated.json",
        generated_at: now(),
      },
      services: svcList,
      infra: infraServices,
      apps: appServices,
    },
  };
}

function deriveDeps(c: any): DerivedFile {
  const deps = c.deps ?? {};
  const perService = deps.node?.per_service ?? [];

  return {
    name: "cloud-data-deps.json",
    data: {
      _meta: {
        generated_by: "cloud-data-config-derive.ts",
        api_route: "GET /c3-api/cloud-data/deps",
        generated_at: now(),
        total_services: perService.length,
        total_packages: Object.keys(deps.node?.merged?.dependencies ?? {}).length +
          Object.keys(deps.node?.merged?.devDependencies ?? {}).length,
      },
      // System deps: flat structure matching existing consumer format
      system: deps.system ?? {},
      ...(deps.build ? { build: deps.build } : {}),
      ...(deps.optional ? { optional: deps.optional } : {}),
      node: {
        merged: deps.node?.merged ?? { dependencies: {}, devDependencies: {} },
        per_service: perService,
      },
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

/** Per-service connection data — resolves service name → IP + port from deploy.host + build.json.
 *
 * Each entry carries enough metadata for any peer-service to introspect another:
 *   { ip, ports, vm }                       — base connectivity (always present)
 *   { domain, description }                 — when declared
 *   { api: { has_api, type, ... } }         — when the peer has an `api` block in its build.json
 *   { mcp: { has_mcp, transport, ... } }    — when the peer has an `mcp` block in its build.json
 *
 * This map flows into every `build-{container}.json` via `deriveContainerConfigs` so any
 * container that wants to introspect peers (e.g. c3-services-api building its API/MCP
 * registry) just reads its own build-{name}.json — no shared cloud-data file needed.
 */
function deriveServiceConnections(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const aliasMap = buildAliasToVm(vms);

  // For each service: resolve deploy.host (ssh alias) → VM → wg_ip, include ports + api/mcp
  const svcMap: Record<string, any> = {};

  for (const [svcName, svc] of Object.entries(services)) {
    const vmEntry = vms[svc.vm];
    if (!vmEntry?.wg_ip) continue;

    // Collect ports: declared_ports (from build.json "ports") takes priority,
    // then supplement with container ports for any roles not already declared
    const ports: Record<string, number> = {};
    if (svc.declared_ports && typeof svc.declared_ports === "object") {
      for (const [k, v] of Object.entries(svc.declared_ports)) {
        if (typeof v === "number") ports[k] = v;
      }
    }
    for (const [role, ct] of Object.entries(svc.containers ?? {})) {
      const port = (ct as any).port;
      if (port && !ports[role]) ports[role] = port;
    }

    svcMap[svcName] = {
      ip: vmEntry.wg_ip,
      ports,
      vm: vmEntry.ssh_alias ?? svc.vm,
      ...(svc.domain ? { domain: svc.domain } : {}),
      ...(svc.description ? { description: svc.description } : {}),
      ...(svc.api ? { api: svc.api } : {}),
      ...(svc.mcp ? { mcp: svc.mcp } : {}),
    };
  }

  // Also include VMs list for services like dagu that need SSH to all VMs
  const vmList = Object.entries(vms)
    .filter(([, vm]: [string, any]) => vm.wg_ip && vm.ssh_alias)
    .map(([vmId, vm]: [string, any]) => ({
      vm_id: vmId,
      alias: vm.ssh_alias,
      ip: vm.wg_ip,
      user: vm.user ?? "ubuntu",
    }));

  return {
    name: "cloud-data-service-connections.json",
    data: {
      _generated: now(),
      services: svcMap,
      vms: vmList,
    },
  };
}

function main() {
  console.log("cloud-data-config-derive: reading consolidated file...\n");

  if (!existsSync(INPUT_JSON)) {
    console.error(`FATAL: consolidated file not found at ${INPUT_JSON}`);
    process.exit(1);
  }

  const consolidated = JSON.parse(readFileSync(INPUT_JSON, "utf-8"));

  if (!existsSync(CLOUD_DATA_DIR)) {
    mkdirSync(CLOUD_DATA_DIR, { recursive: true });
  }
  if (!existsSync(ARCHIVE_DIR)) {
    mkdirSync(ARCHIVE_DIR, { recursive: true });
  }

  // Run all derivations (19 + per-VM container manifests)
  const derived: DerivedFile[] = [
    ...deriveVmContainerManifests(consolidated),
    deriveServiceConnections(consolidated),
    deriveDnsServices(consolidated),
    deriveCaddy(consolidated),
    deriveAutheliaAcl(consolidated),
    deriveAuthelia(consolidated),
    deriveRedis(consolidated),
    ...deriveContainerConfigs(consolidated),
    deriveHomeManager(consolidated),
    deriveGhaConfig(consolidated),
    deriveWireguardPeers(consolidated),
    deriveFirewallRules(consolidated),
    deriveMonitoringTargets(consolidated),  // legacy → z_archive
    deriveBuildReports(consolidated),       // new pattern → dist/build-reports.json
    deriveBackupTargets(consolidated),
    deriveContainerResources(consolidated),
    deriveLogRouting(consolidated),
    deriveCloudflareDns(consolidated),
    deriveMatomoSites(consolidated),
    deriveNtfyAcl(consolidated),
    deriveTopology(consolidated),
    deriveConfigs(consolidated),
    deriveDeps(consolidated),
    deriveDatabases(consolidated),
    deriveSecretsEnvVarNames(consolidated),
  ];

  // Write all files (inject DO NOT EDIT header into each)
  const DO_NOT_EDIT = "AUTO-GENERATED by cloud-data-config-derive.ts — DO NOT EDIT. Source: cloud-data/1_workflows/src/scripts/cloud-data-config-derive.ts";
  const summary: string[] = [];
  for (const file of derived) {
    const path = join(targetDirFor(file.name), file.name);
    const output = typeof file.data === "object" && !Array.isArray(file.data)
      ? { _warning: DO_NOT_EDIT, ...file.data }
      : file.data;
    const json = JSON.stringify(output, null, 2) + "\n";
    writeFileSync(path, json);

    // Count top-level entries for summary
    const data = file.data as any;
    let countStr = "";
    if (data.services && typeof data.services === "object") {
      const count = Array.isArray(data.services) ? data.services.length : Object.keys(data.services).length;
      countStr = `${count} entries`;
    } else if (data.rules) {
      countStr = `${Array.isArray(data.rules) ? data.rules.length : Object.keys(data.rules).length} rules`;
    } else if (data.vms && typeof data.vms === "object") {
      const count = Array.isArray(data.vms) ? data.vms.length : Object.keys(data.vms).length;
      countStr = `${count} VMs`;
    } else if (data.targets) {
      countStr = `${data.targets.length} targets`;
    } else if (data.records) {
      countStr = `${data.records.length} records`;
    } else if (data.sites) {
      countStr = `${data.sites.length} sites`;
    } else if (data.topics) {
      countStr = `${Object.keys(data.topics).length} topics`;
    } else if (data.mesh_peers) {
      countStr = `${data.mesh_peers.length} peers`;
    } else if (data.routes) {
      countStr = `${data.routes.length} routes`;
    }

    const subdir = targetDirFor(file.name) === ARCHIVE_DIR ? "z_archive/" : "";
    summary.push(`  ${(subdir + file.name).padEnd(52)} ${countStr}`);
  }

  // Generate manifest.json for the web dashboard sidebar.
  // Paths in the manifest reflect on-disk location: archived files live in dist/z_archive/.
  const manifestEntries = [
    { file: "_cloud-data-consolidated.json", name: "_cloud data consolidated" },
    ...derived.map((f) => {
      const archived = targetDirFor(f.name) === ARCHIVE_DIR;
      return {
        file: archived ? `z_archive/${f.name}` : f.name,
        name: f.name.replace(/\.json$/, "").replace(/cloud-data-/, "cloud data ").replace(/-/g, " ")
          + (archived ? " (archived)" : ""),
      };
    }),
  ];
  // dist/manifest.json — paths relative to dist/ (for tooling that reads dist directly)
  const manifestJson = JSON.stringify(manifestEntries, null, 2) + "\n";
  writeFileSync(join(CLOUD_DATA_DIR, "manifest.json"), manifestJson);
  // 2_configs/manifest.json — paths with dist/ prefix (for dashboard at cloud/ root)
  const rootManifest = manifestEntries.map((e) => ({ ...e, file: `dist/${e.file}` }));
  writeFileSync(join(CONFIGS_DIR, "manifest.json"), JSON.stringify(rootManifest, null, 2) + "\n");

  console.log(`cloud-data-config-derive: wrote ${derived.length} files + manifest.json:\n`);
  for (const line of summary) {
    console.log(line);
  }

  console.log("\ncloud-data-config-derive: done.");
}

main();
