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

/**
 * Stable empty string for `_generated` / `generated_at` fields.
 *
 * Earlier this returned a wall-clock timestamp, then SOURCE_DATE_EPOCH from git
 * HEAD. Both broke FIRE RULE 3 — wall-clock obviously, and SOURCE_DATE_EPOCH
 * via pre-commit because pre-commit runs BEFORE the commit object exists, so
 * `git log -1 HEAD` returns the PARENT commit's time. Every new commit then
 * embedded a different parent timestamp, marking all ~100 dist/ files as
 * "changed" and exploding the Ship matrix fanout per commit.
 *
 * The fields are pure observability metadata — nothing reads them at runtime.
 * Returning `""` keeps the JSON shape stable while making the bytes truly
 * reproducible: same content in → same bytes out, every commit.
 */
function now(): string {
  return "";
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

function deriveCaddy(c: any): DerivedFile[] {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const flatRoutes: any[] = c.configs?.caddy?.routes ?? [];

  // ── wg-public peer lookup (Phase 4 of public-surface collapse plan) ──────
  // Source: c.wireguard_public.peers[] (declared in cloud-data). When Caddy's
  // deploy host is itself a wg-public peer, reverse-proxy upstreams to OTHER
  // wg-public peers travel via the public-trust mesh (10.1.0.x) instead of
  // the internal wg0 (10.0.0.x) — keeps blast-radius bounded if the public
  // edge is compromised. VMs not in wg-public (e.g. gcp-t4) silently fall
  // back to wg0. Zero hardcoded IPs — everything reads cloud-data peers list.
  const wgPublicPeers: Array<{ name: string; wg_ip: string }> = c.wireguard_public?.peers ?? [];
  const aliasToWgPublicIp: Record<string, string> = {};
  for (const peer of wgPublicPeers) {
    if (peer.name && peer.wg_ip) aliasToWgPublicIp[peer.name] = peer.wg_ip;
  }
  const caddySvcForVm = services["caddy"];
  const caddyVmObj = caddySvcForVm ? vms[caddySvcForVm.vm] : null;
  const caddyHostAlias: string = caddyVmObj?.ssh_alias ?? "";
  // wg-public is hub-and-spoke (only hub has all peers in allowed_ips). Spoke
  // → spoke routing through the hub is not enabled, so Caddy can only use
  // wg-public IPs when Caddy itself runs on the hub. On a spoke host (e.g.
  // gcp-proxy), fall back to wg0 for all upstreams.
  const caddyWgPublicPeer = wgPublicPeers.find((p: any) => p.name === caddyHostAlias);
  const caddyOnWgPublicHub = caddyWgPublicPeer?.role === "hub";

  /**
   * Resolve a VM's upstream IP for Caddy. Only when Caddy runs on the
   * wg-public hub AND the target VM is also a wg-public peer is the
   * wg-public IP used; otherwise fall back to wg0. Pure function of
   * cloud-data — no hardcoded IPs anywhere.
   */
  const resolveVmIpForCaddy = (vm: any): string => {
    const wg0 = vm?.wg_ip ?? "";
    if (!caddyOnWgPublicHub) return wg0;
    const alias = vm?.ssh_alias ?? "";
    return aliasToWgPublicIp[alias] ?? wg0;
  };

  /**
   * Rewrite a service's `<wg0_ip>:<port>` upstream string to the
   * caddy-reachable IP (wg-public preferred when applicable). Pass-through
   * if the upstream doesn't start with the VM's wg0 IP (e.g. a static
   * hostname-based upstream).
   */
  const rewriteUpstreamForCaddy = (vmId: string | undefined, upstream: string | undefined): string | undefined => {
    if (!upstream || !vmId) return upstream;
    const vm = vms[vmId];
    if (!vm?.wg_ip) return upstream;
    if (!upstream.startsWith(`${vm.wg_ip}:`)) return upstream;
    const newIp = resolveVmIpForCaddy(vm);
    if (!newIp || newIp === vm.wg_ip) return upstream;
    return upstream.replace(`${vm.wg_ip}:`, `${newIp}:`);
  };

  // Build dns→<caddy-reachable>ip map (resolves any lingering name.app:port → IP:port).
  // Uses the wg-public preference when applicable.
  const dnsToIp: Record<string, string> = {};
  for (const [, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip || !svc.dns) continue;
    const ip = resolveVmIpForCaddy(vm);
    dnsToIp[svc.dns] = ip;
    for (const ct of Object.values(svc.containers ?? {})) {
      const c = ct as any;
      if (c.dns) dnsToIp[c.dns] = ip;
    }
  }
  const resolveUpstream = (upstream: string | undefined): string | undefined => {
    if (!upstream) return upstream;
    const m = upstream.match(/^([a-z0-9-]+\.app):(\d+)$/);
    if (m && dnsToIp[m[1]]) return `${dnsToIp[m[1]]}:${m[2]}`;
    return upstream;
  };

  // ── L4 routes: derive from each service's proxy.primary.l4_ports ──
  // Source-of-truth = the service that owns the port (maddy, stalwart, …).
  // Each service declares in its build.json:
  //   proxy.primary.l4_ports: [
  //     { port: 993, upstream: "<host>:993", protocol: "tls", comment: "..." }
  //   ]
  // The deploy.host of that service determines which VM is the upstream.
  // Caddy on its host binds the listed ports and TLS-passthroughs to upstream.
  // Phase 4: aliasToWgIp routes via wg-public when caddy host is a member.
  const l4Routes: any[] = [];
  // Caddy's own listen-scope=wg target IP — used when a route declares
  // listen_scope: "wg" so Caddy binds to its own WG interface only (not 0.0.0.0).
  // When Caddy lives on the wg-public hub (oci-analytics) we bind to its
  // wg-public IP (10.1.0.1); otherwise to its wg0 IP. Pure data lookup.
  let caddyListenScopeWgIp = "";
  if (caddyVmObj) {
    caddyListenScopeWgIp = caddyOnWgPublicHub
      ? aliasToWgPublicIp[caddyHostAlias]
      : (caddyVmObj.wg_ip ?? "");
  }
  // ssh_alias → caddy-reachable IP (wg-public preferred when caddy is on it,
  // wg0 otherwise). Used to rewrite "<alias>:port" upstreams.
  const aliasToWgIp: Record<string, string> = {};
  for (const vm of Object.values(vms) as any[]) {
    if (vm.ssh_alias && vm.wg_ip) aliasToWgIp[vm.ssh_alias] = resolveVmIpForCaddy(vm);
  }
  for (const [, svc] of Object.entries(services)) {
    const l4Ports = (svc as any).proxy?.primary?.l4_ports ?? [];
    if (!Array.isArray(l4Ports) || l4Ports.length === 0) continue;
    const deployHost = (svc as any).deploy?.host ?? (svc as any).vm ?? "";
    const fallbackIp = aliasToWgIp[deployHost] ?? "";
    for (const lp of l4Ports) {
      if (typeof lp.port !== "number") continue;
      // Resolve upstream: explicit lp.upstream wins; otherwise <fallbackIp>:<port>.
      // Rewrite "<alias>:port" → "<caddy-reachable wg ip>:port" if alias matches a known VM.
      let upstream = (lp.upstream as string | undefined) ?? "";
      if (upstream) {
        const m = upstream.match(/^([^:]+):(\d+)$/);
        if (m && aliasToWgIp[m[1]]) upstream = `${aliasToWgIp[m[1]]}:${m[2]}`;
      } else if (fallbackIp) {
        upstream = `${fallbackIp}:${lp.port}`;
      }
      if (!upstream) continue;
      const route: any = { port: lp.port, upstream, comment: lp.comment ?? `L4 passthrough (${(svc as any).name ?? "?"})` };
      // listen_scope = "wg" → bind Caddy's listener to its own WG IP only.
      if (lp.listen_scope === "wg") {
        if (!caddyListenScopeWgIp) {
          throw new Error(`listen_scope=wg on port ${lp.port} but caddy host has no resolvable WG IP`);
        }
        route.listen = `${caddyListenScopeWgIp}:${lp.port}`;
      }
      // sni → caddy-l4 SNI matcher; multiple routes sharing the same listen
      // spec collapse into one listener with per-SNI sub-routes (caddyfile.nix
      // groups them). Phase 3 of public-surface collapse plan: lets IMAPS,
      // SMTPS, JMAP all share :443 via SNI hostname routing.
      if (typeof lp.sni === "string" && lp.sni.length > 0) {
        route.sni = lp.sni;
      }
      l4Routes.push(route);
    }
  }

  // ── Fleet posture: WG-only by default (fail-closed) ──
  // A public-edge route is gated to the WG mesh (10.0.0.0/24) by caddyfile.nix
  // UNLESS its build.json explicitly declares `proxy.primary.wg_only: false`.
  // i.e. omitted → WG-only; new/unclassified services are private by default.
  // Setting `wg_only: false` is the deliberate, self-documenting opt-out for
  // the handful of routes that MUST stay public (mesh bootstrap, inbound-mail
  // ingress, public-site analytics beacons, Matrix federation, c3-public-api).
  // Source of truth: service build.json proxy.primary.wg_only.
  // Applies to every public-edge emitter below (subdomain, path, mcp, ntfy,
  // proxy_dashboard). NOT applied to special.analytics (matomo/umami public
  // tracking beacons) or to internal :80 catalog / .app synthesis routes.
  const wgOnly = (proxy: any): boolean => (proxy?.wg_only ?? true);

  // ── Domain routes: services with domain-level proxy ──
  const routes: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy?.domain || proxy.type === "path" || proxy.type === "special" || proxy.streaming || proxy.base_path) continue;
    if (!svc.upstream) continue; // Skip services with no HTTP upstream (e.g. Maddy — SMTP/IMAP only, no web UI)
    const upstreamForCaddy = rewriteUpstreamForCaddy(svc.vm, svc.upstream);
    const route: any = {
      domain: proxy.domain,
      ...(upstreamForCaddy ? { upstream: upstreamForCaddy } : {}),
      ...(proxy.landing_page ? { landing_page: proxy.landing_page } : {}),
      ...(proxy.tls_skip_verify ? { tls_skip_verify: true } : {}),
      ...(proxy.auth === "none" ? { auth: "none" } : {}),
      // wg_only: when set, caddyfile.nix gates the whole route behind a
      // `remote_ip 10.0.0.0/24` matcher (403 for anything off the WG mesh).
      // Fail-closed default (wgOnly): WG-only unless build.json sets wg_only:false.
      ...(wgOnly(proxy) ? { wg_only: true } : {}),
      // root_response_json: static JSON served at GET /. Used to override
      // upstreams that bake their internal listener port into responses
      // (e.g. Stalwart JMAP Session leaks :2443). Caddy emits `handle /`
      // with `respond <json> 200` + Content-Type: application/json. Other
      // paths still flow to the reverse_proxy upstream.
      ...(proxy.root_response_json ? { root_response_json: proxy.root_response_json } : {}),
      // Per-path Authelia bypass for primary-domain routes. The caddyfile.nix
      // template already renders `route.bypass_paths` as `handle <pp> {
      // reverse_proxy <upstream> }` BEFORE the @bearer/authed handle blocks
      // (caddyfile.nix:323+323). Caddy's first-match-wins puts the bypass
      // path on the no-auth path; everything else still hits Authelia. Used
      // for mobile-app login endpoints (e.g. Mattermost's /api/v4/*) where
      // the app posts JSON credentials and can't follow a 302 redirect.
      ...(proxy.bypass_paths ? { bypass_paths: proxy.bypass_paths } : {}),
      comment: svc.description,
    };
    routes.push(route);
  }
  // introspect-proxy is caddy-internal (no external route — consumed by Caddy's forward_auth)

  // ── Path routes: group by parent_domain ──
  const pathGroups: Record<string, { paths: any[]; comment: string; fallback?: string; landing_page?: string }> = {};

  for (const [, svc] of Object.entries(services)) {
    if (svc.enabled === false) continue;  // honour build.json toggle (parity with the 4 other loops in this file)
    const proxy = svc.proxy?.primary;
    if (!proxy || proxy.streaming) continue;
    // Include explicit path type OR services with base_path (implicit path route)
    const isPathRoute = proxy.type === "path" || (proxy.base_path && proxy.domain);
    if (!isPathRoute) continue;
    const pd = proxy.parent_domain ?? proxy.domain;
    if (!pd) continue;
    if (!pathGroups[pd]) pathGroups[pd] = { paths: [], comment: "" };
    const upstreamForCaddy = rewriteUpstreamForCaddy(svc.vm, svc.upstream);
    pathGroups[pd].paths.push({
      base_path: proxy.base_path,
      ...(upstreamForCaddy ? { upstream: upstreamForCaddy } : {}),
      ...(proxy.public_paths ? { public_paths: proxy.public_paths } : {}),
      // Fail-closed default (wgOnly): WG-only unless build.json sets wg_only:false.
      // caddyfile.nix mkPathEntry wraps the per-path handle (incl. public_paths)
      // in a `remote_ip 10.0.0.0/24` gate → 403 off-mesh.
      ...(wgOnly(proxy) ? { wg_only: true } : {}),
      comment: svc.description,
    });
    // extra_paths: additional routes on the same parent_domain that proxy to a
    // different upstream service. Declared in build.json proxy.primary.extra_paths[].
    // upstream_service resolves to the named service's upstream (data-driven, no IPs).
    for (const ep of (proxy.extra_paths ?? [])) {
      if (!ep.base_path || !ep.upstream_service) continue;
      const epSvc = (services as Record<string, any>)[ep.upstream_service];
      if (!epSvc?.upstream) continue;
      const epUpstream = rewriteUpstreamForCaddy(epSvc.vm, epSvc.upstream);
      if (!epUpstream) continue;
      pathGroups[pd].paths.push({
        base_path: ep.base_path,
        upstream: epUpstream,
        ...(wgOnly(ep) ? { wg_only: true } : {}),
        comment: `${ep.upstream_service} proxy (extra_path declared by ${svc.folder ?? "?"})`,
      });
    }
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

  // ── GitHub Pages proxies: aggregated from any service's proxy.github_pages_proxies[] ──
  // Each service declares its own routes in its build.json — there is no
  // privileged service that owns this list. The canonical declarer today is
  // a_solutions/user-web_front-end/build.json (a data-only "service" that bundles
  // every diegonmarcos.github.io reverse-proxy host). Any future service may
  // also contribute entries by adding a `proxy.github_pages_proxies[]` array.
  const githubPagesProxies: any[] = [];
  for (const svc of Object.values(services) as any[]) {
    const proxies = (svc.proxy?.github_pages_proxies ?? []) as any[];
    for (const entry of proxies) {
      githubPagesProxies.push({
        domain: entry.domain,
        github_path: entry.github_path,
        ...(entry.wkd ? { wkd: true } : {}),
        ...(entry.comment ? { comment: entry.comment } : {}),
      });
    }
  }

  // ── MCP routes: streaming services ──
  const mcpEndpoints: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy?.streaming || !proxy.parent_domain) continue;
    const upstreamForCaddy = rewriteUpstreamForCaddy(svc.vm, svc.upstream);
    mcpEndpoints.push({
      base_path: proxy.base_path,
      ...(upstreamForCaddy ? { upstream: upstreamForCaddy } : {}),
      // wg_only: caddyfile.nix mkMcpRouteGroup gates this endpoint behind a
      // `remote_ip 10.0.0.0/24` matcher. Needed because the MCP hub emits no
      // Authelia/bearer — without this the endpoint is fully public.
      // Fail-closed default (wgOnly): WG-only unless build.json sets wg_only:false.
      ...(wgOnly(proxy) ? { wg_only: true } : {}),
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
    // Resolve the rss-gateway sidecar upstream from the gateway port + VM WG IP.
    // The gateway runs on oci-apps (same VM as ntfy) — use vms[vm].wg_ip (in-scope here).
    // Port comes from svc.declared_ports (the consolidator renames build.json
    // `ports` → `declared_ports`; raw `.ports` is undefined post-consolidation —
    // this was the `gateway_upstream: null` bug the ntfy-profiles tester caught).
    const ntfyGatewayPort = ntfySvc.declared_ports?.rss_gateway ?? ntfySvc.ports?.rss_gateway;
    const ntfyVmWgIp = vms[ntfySvc.vm]?.wg_ip;
    const gatewayRaw = ntfyGatewayPort && ntfyVmWgIp ? `${ntfyVmWgIp}:${ntfyGatewayPort}` : undefined;
    const gatewayUpstream = gatewayRaw ? rewriteUpstreamForCaddy(ntfySvc.vm, gatewayRaw) : undefined;
    special.ntfy = {
      domain: ntfySvc.domain ?? ntfySvc.proxy?.primary?.domain,
      upstream: rewriteUpstreamForCaddy(ntfySvc.vm, ntfySvc.upstream),
      ...(gatewayUpstream ? { gateway_upstream: gatewayUpstream } : {}),
      comment: "ntfy notifications -- 3-tier auth: JWT bearer, tk_ bearer, cookie",
      // Fail-closed default (wgOnly): WG-only unless build.json sets wg_only:false.
      ...(wgOnly(ntfySvc.proxy?.primary) ? { wg_only: true } : {}),
      // feed_auth:"none" → caddyfile.nix serves /feed/* with no Authelia/bearer
      // (the whole site is already wg0-gated). Cloud Mail polls the RSS tree
      // over the mesh without a token.
      ...(ntfySvc.proxy?.primary?.feed_auth === "none" ? { feed_auth: "none" } : {}),
    };
  }

  // analytics (matomo + umami)
  const matomoSvc = services["matomo"];
  const umamiSvc = services["umami"];
  if (matomoSvc) {
    const matomoUp = rewriteUpstreamForCaddy(matomoSvc.vm, matomoSvc.upstream);
    const umamiUp = umamiSvc ? rewriteUpstreamForCaddy(umamiSvc.vm, umamiSvc.upstream) : undefined;
    special.analytics = {
      domain: matomoSvc.domain ?? matomoSvc.proxy?.primary?.domain,
      comment: "Matomo (public tracking + protected admin) + Umami (path-based)",
      matomo_upstream: matomoUp,
      ...(umamiUp ? { umami_upstream: umamiUp } : {}),
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
      // Fail-closed default (wgOnly): WG-only unless build.json sets wg_only:false.
      ...(wgOnly(caddySvc.proxy?.primary) ? { wg_only: true } : {}),
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
  // Each upstream is rewritten through resolveVmIpForCaddy so that Caddy on
  // a wg-public host (Phase 4: oci-analytics) prefers wg-public IPs for peer
  // VMs; non-peer VMs (e.g. gcp-t4) keep their wg0 IPs unchanged.
  const internalRoutes: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    if (svc.enabled === false) continue;
    if (!svc.upstream || !svc.dns) continue;
    // Skip services whose containers are all marked public: false (e.g. redis,
    // postgres sidecars). They're docker-internal only — not reachable via the
    // WG mesh, so emitting a Caddy/Hickory catalog row creates a phantom probe
    // target. Matches the same guard used in allAppUrls (line 753).
    const ctsArr = Object.values(svc.containers ?? {}) as any[];
    if (ctsArr.length > 0 && ctsArr.every(c => c.public === false)) continue;
    const vm = vms[svc.vm];
    let upstream: string = svc.upstream;
    if (vm?.wg_ip && upstream.startsWith(`${vm.wg_ip}:`)) {
      const newIp = resolveVmIpForCaddy(vm);
      upstream = upstream.replace(`${vm.wg_ip}:`, `${newIp}:`);
    }
    internalRoutes.push({
      service: svc.dns,
      upstream,
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
          upstream: `${resolveVmIpForCaddy(vm)}:${bj.dashboard.port ?? 7680}`,
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
  // Rewrite via resolveVmIpForCaddy so wg-public peers cross the public-trust
  // mesh when caddy is on a wg-public host (Phase 4).
  const authUpstreams: Record<string, string> = {};
  const authSvc = services["authelia"];
  const authUp = authSvc ? rewriteUpstreamForCaddy(authSvc.vm, authSvc.upstream) : undefined;
  if (authUp) authUpstreams.authelia = authUp;
  const introspectSvc = services["introspect-proxy"];
  const introspectUp = introspectSvc ? rewriteUpstreamForCaddy(introspectSvc.vm, introspectSvc.upstream) : undefined;
  if (introspectUp) authUpstreams.introspect_proxy = introspectUp;

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
        // Skip ports that are loopback-only (`bind: "127.0.0.1"`) or
        // explicitly flagged `monitor: false` (e.g. caddy admin :2019,
        // caddy raw :80, stalwart :2025 shadow delivery). Listened-to by
        // local processes but never reachable from the WG mesh, so a
        // canonical .app URL probe would always fail.
        // Data-driven via build.json — both signals already declared:
        //   `"bind": "127.0.0.1"`  → service-defined binding scope
        //   `"monitor": false`     → explicit opt-out for non-bind cases
        if (typeof ep !== "object" || typeof ep.port !== "number" || !ep.protocol) continue;
        if (ep.monitor === false) continue;
        // bind may be a string ("10.0.0.3") or an array (["10.0.0.3", "10.1.0.3"]).
        // A port is loopback-only iff EVERY bind is loopback. Skip in that case.
        const binds: string[] = Array.isArray(ep.bind) ? ep.bind : (ep.bind ? [ep.bind] : []);
        if (binds.length > 0 && binds.every(b => b === "127.0.0.1" || b === "::1")) continue;
        add(ep.port, ep.protocol, `containers.${ck}.extra_ports`);
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
        // Upstream IP precedence (pure data lookups, no hardcoded IPs):
        //   1. containers.<x>.bind_host — the container DECLARES the exact
        //      interface it listens on (e.g. cf-worker-bridge binds the
        //      wg-public hub IP 10.1.0.1, not the VM's wg0 IP). Probing or
        //      proxying any other IP is guaranteed connection-refused.
        //   2. resolveVmIpForCaddy(vm) — caddy-reachable VM IP (wg-public
        //      preferred when caddy is on a wg-public host, wg0 otherwise).
        // Mirrors the same precedence in cloud-data-config-consolidated.ts.
        const vmIpForCaddy = resolveVmIpForCaddy(vm);
        const upstreamIp = (typeof c.bind_host === "string" && c.bind_host) ? c.bind_host : vmIpForCaddy;
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
            upstream: `${upstreamIp}:${port}`,
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
            upstream: `${resolveVmIpForCaddy(vm)}:${c.port}`,
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
            upstream: `${resolveVmIpForCaddy(vm)}:${edb.port}`,
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

  // ── well_known routes: aggregated from per-service proxy.well_known[] ──
  // Used by caddyfile.nix mkGithubPagesRoute to attach .well-known handlers
  // to a target_domain's GitHub Pages block (e.g. /.well-known/jmap on the
  // apex diegonmarcos.com → reverse-proxies to Stalwart's JMAP listener).
  // Each entry: { path, target_domain, upstream, tls_skip_verify, comment }.
  // upstream is auto-resolved from the service's caddy-reachable IP + the
  // declared port (default: the service's web/JMAP port; fallback :443).
  const wellKnownRoutes: any[] = [];
  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    const wkEntries: any[] = svc.proxy?.well_known ?? [];
    if (!wkEntries.length) continue;
    const vm = vms[svc.vm];
    const ip = vm ? resolveVmIpForCaddy(vm) : null;
    for (const wk of wkEntries) {
      if (!wk.path || !wk.target_domain) continue;
      // Two modes: (a) reverse_proxy to an upstream, or (b) redirect to a URL.
      // redirect_to wins if both are declared. Used by JMAP autoconfig to
      // bounce the apex /.well-known/jmap to our static Session JSON on the
      // service's primary domain (avoiding upstream-baked URL leaks).
      if (wk.redirect_to) {
        wellKnownRoutes.push({
          path: wk.path,
          target_domain: wk.target_domain,
          redirect_to: wk.redirect_to,
          comment: wk.comment ?? `${wk.path} → redirect ${svcName}`,
        });
        continue;
      }
      // Resolve upstream: explicit wk.upstream wins, else service IP+port
      const port = wk.upstream_port ?? svc.upstream?.split(":")[1] ?? "443";
      const upstream = wk.upstream
        ?? (ip ? `${ip}:${port}` : null);
      if (!upstream) continue;
      wellKnownRoutes.push({
        path: wk.path,
        target_domain: wk.target_domain,
        upstream,
        ...(wk.tls_skip_verify ? { tls_skip_verify: true } : {}),
        comment: wk.comment ?? `${wk.path} → ${svcName}`,
      });
    }
  }

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

  const mainFile: DerivedFile = {
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
      well_known_routes: wellKnownRoutes,
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

  // ── build-caddy-public.json — DECLARED-PUBLIC allowlist for caddy-public (oci-analytics edge) ──
  // Source of truth: wg_only !== true (private = wg_only:true; public = field omitted). This is the
  // SAME flag the gcp-proxy @wg gate keys on, so the edge allowlist and the hub gate can NEVER
  // diverge. NOT the public_* taxonomy — that is a ZONE label that includes wg_only:true MCP/API
  // services (e.g. mcp.../cloud-cgc-mcp), so using it would expose ~32 private services.
  const isPublic = (e: any) => e?.wg_only !== true;
  const publicSubdomainRoutes = dedupedRoutes.filter(isPublic);
  const publicPathRoutes = filteredPathRoutes
    .map((g: any) => ({
      ...g,
      paths: (g.paths ?? []).filter((p: any) => isPublic(p) || ((p.public_paths ?? []).length > 0)),
    }))
    .filter((g: any) => (g.paths ?? []).length > 0);
  const publicMcpRoutes = mcpRoutes
    .map((g: any) => ({ ...g, endpoints: (g.endpoints ?? []).filter(isPublic) }))
    .filter((g: any) => (g.endpoints ?? []).length > 0);

  // NOTE: named build-caddy-EDGE.json (not build-caddy-public.json) to avoid colliding with the
  // per-container manifest deriveContainerConfigs emits for the `caddy-public` service.
  const publicFile: DerivedFile = {
    name: "build-caddy-edge.json",
    data: {
      _meta: {
        description: "Declared-public allowlist for caddy-public edge (oci-analytics). Source: wg_only!==true. NOT the public_* zone taxonomy.",
        format_version: 1,
      },
      _generated: now(),
      _source: "deriveCaddy → routes/path_routes/mcp_routes filtered to wg_only!==true + gh-pages + well-known",
      global:            caddyCfg.global            ?? {},
      on_demand_tls:     caddyCfg.on_demand_tls     ?? {},
      security_snippets: caddyCfg.security_snippets ?? {},
      auth:              caddyCfg.auth              ?? {},
      auth_upstreams:    authUpstreams,
      error_handler:     caddyCfg.error_handler     ?? {},
      catch_all:         caddyCfg.catch_all         ?? {},
      messages:          caddyCfg.messages          ?? {},
      // caddy-public is the smart L4+L7 edge (caddy-l4 image). Its layer4 SNI-muxes:
      //   · mail_l4_routes (imap./smtps.) → L4-forward to maddy (raw IMAPS/SMTPS — never L7);
      //   · public_sni_hosts (pure-public: gh-pages + auth=none subdomains) → local :8443 L7 serve;
      //   · everything else → L4 raw-TLS passthrough to private_forward_upstream (gcp-proxy), where
      //     the @wg gate decides. Passthrough (not termination) avoids any TLS re-encryption AND
      //     keeps mixed hosts (api./analytics.) served by gcp-proxy's existing routing.
      // Non-served requests reach gcp-proxy over wg-PUBLIC (10.1.0.2) → @wg 403 for private. NEVER wg0.
      private_forward_upstream: "10.1.0.2:443",
      mail_l4_routes:       (l4Routes ?? []).filter((r: any) => r && r.sni),
      // Only hosts caddy-public SERVES at L7 (gh-pages + auth=none subdomains).
      // Authed-public subdomains are NOT here — they passthrough to gcp-proxy where
      // their auth lives. Anything not in this list is L4-passthrough'd to the hub.
      public_sni_hosts: [
        ...githubPagesProxies.flatMap((g: any) => String(g.domain).split(",").map((s: string) => s.trim())),
        ...publicSubdomainRoutes.filter((r: any) => (r.auth ?? null) === "none").map((r: any) => r.domain),
      ],
      public_routes:        publicSubdomainRoutes,
      public_path_routes:   publicPathRoutes,
      public_mcp_routes:    publicMcpRoutes,
      github_pages_proxies: githubPagesProxies,
      well_known_routes:    wellKnownRoutes,
    },
  };

  return [mainFile, publicFile];
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

/** Generic: emit one build-{name}.json per service.
 *
 *  Two emission modes:
 *    1. Service WITH containers — emit one build-{container_name}.json per
 *       container (matches the deployed Docker container_name; used by
 *       compose / health drift detection). Skips containers that already
 *       have a specialized derive function (caddy, authelia, redis).
 *    2. Service WITHOUT containers (terraform, cloudflare-worker, agi
 *       images, etc.) — emit a single build-{service_name}.json so every
 *       declared service has a self-contained file consumers can read.
 *
 *  Each file contains:
 *    - container (or null): the per-container spec from build.json
 *    - service: the service name
 *    - role: container role (app, db, ...) — null for service-without-containers
 *    - vm: the deploy target alias
 *    - services: cross-service registry map (every peer's ip/ports/vm/api/mcp)
 *
 *  Adding a new container/service auto-creates its build-{name}.json on the
 *  next derive run — zero engine edits required.
 */
/**
 * Resolve a service's mail_clients block into a fully-resolved mail_accounts
 * block. Looks up peers' users{} + extra_ports{service: <label>} to materialise
 * {host, port, secure, login, pass_env} for each via_internal entry.
 *
 * Returns null if the service has no mail_clients block (most services).
 *
 * Source-of-truth contract:
 *  - peer.users[K]               → SoT for mailbox identity (name + pass_env)
 *  - peer.extra_ports[N].service → SoT for protocol channel (port + secure)
 *  - peer.domain                 → SoT for hostname
 *  - cypht.mail_clients (caller) → SoT for which combos cypht consumes
 */
function resolveMailAccounts(svcName: string, services: Record<string, any>): any | null {
  const svc = services[svcName];
  const mc = svc?.mail_clients;
  if (!mc) return null;

  const PROTO_SECURE: Record<string, string> = {
    "tls": "SSL", "starttls": "STARTTLS", "ssl": "SSL", "tcp": "PLAIN",
  };

  // Find an extra_ports entry by service label; return resolved channel info.
  const lookupChannel = (peerName: string, label: string): { host: string; port: number; secure: string } | null => {
    const peer = services[peerName];
    if (!peer || !peer.domain) return null;
    const ep = peer.extra_ports ?? {};
    for (const [portStr, info] of Object.entries<any>(ep)) {
      if (info?.service === label) {
        return {
          host:   peer.domain,
          port:   parseInt(portStr, 10),
          secure: PROTO_SECURE[(info.protocol ?? "tls").toLowerCase()] ?? "SSL",
        };
      }
    }
    return null;
  };

  // Resolve "<service>.users.<key>" → {address, pass_env, name, peer}
  const resolveUserRef = (ref: string): { address: string; pass_env: string; name: string; peer: string; userKey: string } | null => {
    const parts = (ref ?? "").split(".");
    if (parts.length !== 3 || parts[1] !== "users") return null;
    const [peerName, , userKey] = parts;
    const peer = services[peerName];
    const u = peer?.users?.[userKey];
    if (!u || !peer.domain) return null;
    return {
      address:  `${u.name}@${peer.domain.split(".").slice(-2).join(".") === peer.domain ? peer.domain.split(".").slice(1).join(".") : peer.domain}`,
      // Address heuristic: maddy.diegonmarcos.com has "me" → me@diegonmarcos.com.
      // Strip the service prefix subdomain (mail., mail-stalwart.) to get the
      // base domain. Done via cutting first label off.
      pass_env: u.pass_env,
      name:     u.name,
      peer:     peerName,
      userKey,
    };
  };

  // Address resolver — strip subdomain prefix to land on base_domain
  const addressOf = (peerName: string, userName: string): string => {
    const peer = services[peerName];
    if (!peer?.domain) return userName;
    // Take everything AFTER the first dot if the domain has 3+ labels
    // (e.g. "mail.diegonmarcos.com" → "diegonmarcos.com").
    const labels = peer.domain.split(".");
    const base = labels.length >= 3 ? labels.slice(1).join(".") : peer.domain;
    return `${userName}@${base}`;
  };

  const renderLabel = (tpl: string, address: string): string => {
    // {addr_short} = local part of email (before @) — UI-friendly.
    // Convention: dnm.com is shorthand for diegonmarcos.com (per user request).
    const SHORTHAND: Record<string, string> = { "diegonmarcos.com": "dnm.com" };
    const [local, dom] = address.split("@");
    const shortDom = SHORTHAND[dom] ?? dom;
    return tpl.replace(/\{addr_short\}/g, `${local}@${shortDom}`)
              .replace(/\{address\}/g,    address);
  };

  // ── primary_user ────────────────────────────────────────────────────
  const primaryRef = resolveUserRef(mc.primary_user?.user_ref ?? "");
  const primary_user = primaryRef ? {
    email:    addressOf(primaryRef.peer, primaryRef.name),
    pass_env: mc.primary_user.pass_env,
  } : null;

  // ── via_internal[] (resolved) + via_external[] (passthrough) → extras
  const extras: any[] = [];
  for (const entry of (mc.via_internal ?? []) as any[]) {
    const userInfo = resolveUserRef(entry.user_ref ?? "");
    if (!userInfo) continue;
    const address = addressOf(userInfo.peer, userInfo.name);
    const label   = renderLabel(entry.label_template ?? "", address);
    const out: any = {
      name:     label,
      email:    entry.alias_email ?? address,
      login:    address,
      pass_env: userInfo.pass_env,
    };
    if (entry.receive_via) {
      const rec = lookupChannel(entry.receive_via.service, entry.receive_via.via);
      if (rec) {
        // Decide IMAP vs JMAP by service label
        if (entry.receive_via.via.startsWith("jmap")) {
          out.jmap = rec;
        } else {
          out.imap = rec;
        }
      }
    }
    if (entry.send_via) {
      const snd = lookupChannel(entry.send_via.service, entry.send_via.via);
      if (snd) out.smtp = snd;
    }
    extras.push(out);
  }
  for (const ext of (mc.via_external ?? []) as any[]) {
    // Skip pure-doc placeholder entries (those that ONLY contain _doc).
    // Real entries have email + pass_env alongside any sibling _doc annotation.
    if (!ext || typeof ext !== "object" || !ext.email) continue;
    extras.push({
      name:     ext.label ?? ext.email,
      email:    ext.email,
      login:    ext.login ?? ext.email,
      pass_env: ext.pass_env,
      ...(ext.imap ? { imap: ext.imap } : {}),
      ...(ext.smtp ? { smtp: ext.smtp } : {}),
      ...(ext.jmap ? { jmap: ext.jmap } : {}),
    });
  }

  // ── carddav (resolve service_ref → peer.domain) ────────────────────
  const carddav: Record<string, any> = {};
  for (const [k, v] of Object.entries<any>(mc.carddav ?? {})) {
    if (k.startsWith("_") || !v || typeof v !== "object") continue;
    const peer = services[v.service_ref];
    const peerUser = resolveUserRef(v.user_ref ?? "");
    if (!peer?.domain) continue;
    carddav[k] = {
      server_template: `https://${peer.domain}${v.path_template ?? "/"}`,
      user_env:        peerUser ? "PRIMARY_EMAIL" : (v.user_env ?? "PRIMARY_EMAIL"),
      pass_env:        v.pass_env,
    };
  }

  // ── feeds (resolve service_ref → peer.domain) ──────────────────────
  let feeds: any = null;
  if (mc.feeds && mc.feeds.service_ref) {
    const peer = services[mc.feeds.service_ref];
    if (peer?.domain) {
      feeds = {
        url_template:  `https://${peer.domain}${mc.feeds.url_path_template ?? "/{topic}"}`,
        topics_source: mc.feeds.topics_source ?? null,
      };
    }
  }

  // ── profiles (resolve user_ref + render match_template) ─────────────
  const profiles: Record<string, any> = {};
  for (const [k, p] of Object.entries<any>(mc.profiles ?? {})) {
    if (k.startsWith("_") || !p || typeof p !== "object") continue;
    const userInfo = resolveUserRef(p.user_ref ?? "");
    const address  = userInfo ? addressOf(userInfo.peer, userInfo.name) : "";
    profiles[k] = {
      name:    p.name,
      address,
      replyto: p.replyto ?? address,
      sig:     p.sig ?? "",
      rmk:     p.rmk ?? "",
      type:    p.type ?? "imap",
      default: !!p.default,
      match:   renderLabel(p.match_template ?? "", address),
    };
  }

  // ── settings (passthrough, strip _doc) ──────────────────────────────
  const settings: Record<string, any> = {};
  for (const [k, v] of Object.entries(mc.settings ?? {})) {
    if (!k.startsWith("_")) settings[k] = v;
  }

  return {
    primary_user,
    extras,
    carddav,
    feeds,
    profiles,
    settings,
    _generated_from: {
      via_internal_count: (mc.via_internal ?? []).length,
      via_external_count: (mc.via_external ?? []).filter((e: any) => e && !e._doc).length,
      peers_referenced:   Array.from(new Set(
        (mc.via_internal ?? []).map((e: any) => e.user_ref?.split(".")[0]).filter(Boolean)
      )),
    },
  };
}

function deriveContainerConfigs(c: any): DerivedFile[] {
  const serviceConnections = deriveServiceConnections(c).data as any;
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const SPECIAL_CASES = new Set(["caddy", "authelia", "redis"]);
  const files: DerivedFile[] = [];

  // Standard svc fields known by the engine — anything else on a service
  // object came via `entry.extra` from the source build.json and must be
  // forwarded into the per-service derived file so consumers can read
  // their slice from there (same pattern as deriveServiceConnections does
  // for `services{}`). Without this, services that own non-container
  // declarative data (e.g. bb-net_wireguard-public owning the wg-public
  // mesh topology) couldn't be consumed via their own build-{name}.json
  // and downstream would have to read the full consolidated.
  const STANDARD_SVC_KEYS = new Set([
    "category", "subcategory", "vm", "folder", "description", "enabled",
    "domain", "flake", "port", "dns", "upstream",
    "containers", "container_names", "all_ports", "all_dns",
    "compose", "proxy", "declared_ports", "health", "monitoring",
    "backup", "notifications", "users", "mail_clients", "fallback_vm",
    "api", "mcp",
  ]);

  function svcExtras(svc: any): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(svc ?? {})) {
      if (!STANDARD_SVC_KEYS.has(k) && !k.startsWith("_")) out[k] = v;
    }
    return out;
  }

  // ── db_engine aliases ────────────────────────────────────────────
  // A container may declare `db_engine` (e.g. "surrealdb"); a flake that
  // wraps the upstream DB image consumes the container slice by engine
  // name (kg-store/src/build-surrealdb.json symlink). We mirror that
  // container's build-{container_name}.json to build-{db_engine}.json.
  //
  // db_engine is NOT globally unique (postgres/redis appear on many
  // containers) and may equal a real container_name. Only alias engine
  // names that are unambiguous — declared by exactly one container, not
  // colliding with any container_name, and not a SPECIAL_CASE — so the
  // alias can never clobber another container's primary file or be
  // order-dependent. Pre-compute the safe set in a first pass.
  const containerNames = new Set<string>();
  const engineCounts = new Map<string, number>();
  for (const svc of Object.values(services)) {
    for (const [, ct] of Object.entries((svc as any).containers ?? {})) {
      const cn = (ct as any).container_name || (svc as any).name;
      if (cn) containerNames.add(cn);
      const eng = (ct as any).db_engine;
      if (eng) engineCounts.set(eng, (engineCounts.get(eng) ?? 0) + 1);
    }
  }
  const safeEngineAliases = new Set<string>();
  for (const [eng, n] of engineCounts) {
    if (n === 1 && !containerNames.has(eng) && !SPECIAL_CASES.has(eng)) {
      safeEngineAliases.add(eng);
    }
  }

  for (const [svcName, svc] of Object.entries(services)) {
    const containers = (svc as any).containers ?? {};
    const containerEntries = Object.entries(containers) as [string, any][];
    const vmEntry = vms[(svc as any).vm];
    const vmAlias = vmEntry?.ssh_alias ?? (svc as any).vm;
    const extras = svcExtras(svc);

    if (containerEntries.length === 0) {
      // Service without containers (terraform-managed, cloudflare-worker,
      // image-only artefacts, or pure data-declaration entries like
      // bb-net_wireguard-public). Emit a single build-{svcName}.json so
      // the service is still discoverable by peers / introspection tooling.
      // Forward any extras (e.g. wireguard_public) so consumers read the
      // slice from their own derived file, not the global consolidated.
      files.push({
        name: `build-${svcName}.json`,
        data: {
          _meta: {
            description: `${svcName} service config (no containers — terraform/image/static)`,
            format_version: 1,
          },
          _generated: now(),
          _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/container-configs",
          container: null,
          service: svcName,
          role: null,
          vm: vmAlias,
          services: serviceConnections.services ?? {},
          ...extras,
        },
      });
      continue;
    }

    // Resolve mail_accounts ONCE per service (only emitted when a service has
    // a mail_clients block, e.g. cypht). Same value attached to every
    // container of that service for consistency.
    const mailAccounts = resolveMailAccounts(svcName, serviceConnections.services ?? {});

    // ntfy_topics propagation: chat-mattermost's ntfy-bridge subscribes to a
    // declared list of ntfy topics. Source of truth lives in
    // bc-obs_ntfy/build.json#.topics, flows through parseNtfy →
    // configs.ntfy.topics in _cloud-data-consolidated.json. The mattermost
    // container (and its mattermost-bots sidecar) reads this list via its
    // src/build-mattermost.json symlink — no separate ntfy-topics.nix file
    // and no sync script. FIRE RULE 4.
    const ntfyTopicsForMattermost: string[] | undefined =
      (svcName === "chat-mattermost"
        ? (c.configs?.ntfy?.topics ?? []).map((t: any) => t.name)
        : undefined);

    for (const [role, ct] of containerEntries) {
      const containerName = ct.container_name || svcName;
      if (SPECIAL_CASES.has(containerName)) continue;
      const containerData = {
        _meta: {
          description: `${containerName} container config (service=${svcName}, role=${role})`,
          format_version: 1,
        },
        _generated: now(),
        _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/container-configs",
        container: ct,
        service: svcName,
        role,
        vm: vmAlias,
        services: serviceConnections.services ?? {},
        ...(mailAccounts ? { mail_accounts: mailAccounts } : {}),
        ...(ntfyTopicsForMattermost ? { ntfy_topics: ntfyTopicsForMattermost } : {}),
        // Forward any non-standard svc fields (came via entry.extra in the
        // source build.json) so per-service consumers can read their slice
        // from build-{containerName}.json instead of the global consolidated.
        // E.g. bb-net_wireguard-public's wireguard_public block lands here.
        ...extras,
      };
      files.push({ name: `build-${containerName}.json`, data: containerData });
      // db_engine alias (only for unambiguous engine names — see
      // safeEngineAliases above). Identical spec, named by engine, so a
      // wrapper flake can consume the slice by engine name
      // (kg-store/src/build-surrealdb.json symlink).
      if (ct.db_engine && safeEngineAliases.has(ct.db_engine)) {
        files.push({ name: `build-${ct.db_engine}.json`, data: containerData });
      }
    }
  }
  return files;
}

/** Emit one build-{name}.json per external consumer registered in
 *  2_configs/src/external-consumers.json. Same shape as the per-container
 *  build-{name}.json files (deriveContainerConfigs), but for non-container
 *  services in other repos (unix/ba_flakes_desktop, cb_containers-builders,
 *  cloud-data/secrets, etc.).
 *
 *  Each registry entry declares which top-level (or dotted) keys of the
 *  consolidated file it wants. The slice's data is extracted via getDeep()
 *  and stamped into the build-{name}.json under the declared `key`.
 *
 *  Special filter `map_to_env_vars`: for the secrets consumer, emits
 *  { <service>: <secret_env_var_names[]> } extracted from services[*].
 */
function getDeep(obj: any, dotPath: string): any {
  if (!dotPath) return obj;
  return dotPath.split(".").reduce((acc: any, k: string) =>
    (acc != null && typeof acc === "object") ? acc[k] : undefined, obj);
}

function deriveExternalConsumers(c: any): DerivedFile[] {
  const REGISTRY = join(CONFIGS_DIR, "src", "external-consumers.json");
  if (!existsSync(REGISTRY)) {
    console.error(`[deriveExternalConsumers] registry not found at ${REGISTRY} — skipping`);
    return [];
  }
  let registry: any;
  try {
    registry = JSON.parse(readFileSync(REGISTRY, "utf-8"));
  } catch (e) {
    console.error(`[deriveExternalConsumers] failed to parse ${REGISTRY}:`, e);
    return [];
  }

  const out: DerivedFile[] = [];
  for (const consumer of registry.consumers ?? []) {
    const slices: Record<string, any> = {};
    for (const sliceDef of consumer.slices ?? []) {
      const { key, from, filter } = sliceDef;
      const raw = getDeep(c, from);
      if (filter === "map_to_env_vars") {
        // services[*].secret_env_vars → { <svc>: <names[]> }
        const out2: Record<string, string[]> = {};
        if (raw && typeof raw === "object") {
          for (const [svcName, svc] of Object.entries<any>(raw)) {
            if (Array.isArray(svc?.secret_env_vars) && svc.secret_env_vars.length > 0) {
              out2[svcName] = svc.secret_env_vars;
            }
          }
        }
        slices[key] = out2;
      } else {
        slices[key] = raw ?? null;
      }
    }
    out.push({
      name: `build-${consumer.name}.json`,
      data: {
        _meta: {
          description: `${consumer.name} external consumer build (${consumer.description ?? ""})`,
          format_version: 1,
          consumer_path: consumer.consumer_path ?? null,
          replaces: consumer.replaces ?? [],
        },
        _generated: now(),
        _source: "_cloud-data-consolidated.json + 2_configs/src/external-consumers.json via cloud-data-config-derive.ts/external-consumers",
        consumer: consumer.name,
        ...slices,
      },
    });
  }
  return out;
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
    // Every VM gets its wg_ip — INCLUDING the WG hub (gcp-proxy). The cloud-
    // builder image runs `wg-quick up wg0` before any ship step and is
    // assigned a 10.0.0.200/24 address (gha-runner peer in
    // _cloud-data-consolidated.json). From there 10.0.0.1 (hub) is reachable
    // exactly like any other peer.
    //
    // The previous `isHub → delete wg_ip + override host = public_ip` branch
    // was a 2026-05-08-era workaround for an older cloud-builder layout that
    // didn't carry WG-tools — it forced GHA to SSH the hub at its public IP.
    // That conflicts with the session-goal hardening (gcp-proxy fully private:
    // no public :22, ssh-firewall.service drops anything not from
    // 10.0.0.0/24). ship.yml already does `.wg_ip // .host` fallback, so
    // including wg_ip universally lets GHA reach gcp-proxy via 10.0.0.1.
    const enriched = { ...ghaVm, wg_ip: mainVm?.wg_ip ?? null, user: ghaVm.user ?? mainVm?.user ?? null };
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

  // ── Sections derived from consolidated.json (no extra inputs) ──────
  // services summary — for cross-checks, drift, status flags.
  const servicesSummary: Record<string, any> = {};
  for (const [svcName, svc] of Object.entries(services)) {
    servicesSummary[svcName] = {
      name: svcName,
      vm: svc.vm,
      domain: svc.domain ?? null,
      enabled: svc.enabled !== false,
      category: svc.category ?? null,
      ports: svc.declared_ports ?? svc.ports ?? null,
      health: svc.health ?? null,
    };
  }
  // dns_services — from svc.dns + svc.containers[*].dns
  const dnsServices: any[] = [];
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.dns) dnsServices.push({ service: svcName, dns: svc.dns });
    if (svc.containers && typeof svc.containers === "object") {
      for (const [ctrKey, ctr] of Object.entries(svc.containers as Record<string, any>)) {
        if (ctr.dns) dnsServices.push({ service: svcName, container: ctrKey, dns: ctr.dns });
      }
    }
  }
  // databases — every container with db_engine OR svc.databases inferred
  const databases: any[] = [];
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.containers && typeof svc.containers === "object") {
      for (const [ctrKey, ctr] of Object.entries(svc.containers as Record<string, any>)) {
        if (ctr.db_engine) {
          databases.push({
            service: svcName,
            container: ctrKey,
            engine: ctr.db_engine,
            port: ctr.port ?? null,
            db_name: ctr.db_name ?? null,
            db_user: ctr.db_user ?? null,
          });
        }
      }
    }
  }
  // topology summary — vms[] with services[] indexed for the report's
  // health_full2 cross-checks.
  const topology: Record<string, any> = {
    vms: Object.fromEntries(
      Object.entries(vms).map(([vmName, vm]: [string, any]) => [
        vmName,
        {
          alias: vm.ssh_alias ?? vmName,
          wg_ip: vm.wg_ip ?? null,
          public_ip: vm.public_ip ?? null,
          user: vm.user ?? null,
          provider: vm.provider ?? null,
          services: Object.entries(services)
            .filter(([_, svc]: [string, any]) => svc.vm === vmName)
            .map(([svcName, _]) => svcName),
        },
      ])
    ),
    services: servicesSummary,
  };

  // ── Sections sourced from inputs/reports-*.json (engine-owned configs) ──
  // These were hand-edited in the legacy cloud-data-{url-health,workflows,
  // repo-scan,sec-scan}.json files. Engine now owns them under
  // 2_configs/src/inputs/reports-*.json. Read verbatim and embed.
  const ENGINE_DIR = import.meta.dirname!;
  const INPUTS_DIR = resolve(ENGINE_DIR, "../inputs");
  const readInput = (file: string): any | undefined => {
    const path = join(INPUTS_DIR, file);
    if (!existsSync(path)) return undefined;
    try {
      return JSON.parse(readFileSync(path, "utf-8"));
    } catch (e) {
      console.error(`[deriveBuildReports] failed to parse ${path}:`, e);
      return undefined;
    }
  };
  const urlHealth = readInput("reports-url-health.json");
  const workflows = readInput("reports-workflows.json");
  const repoScan = readInput("reports-repo-scan.json");
  const secScan = readInput("reports-sec-scan.json");
  const runtimeAllowlist = readInput("reports-runtime-allowlist.json");
  // R2: DNS resolvers (hickory/public/google) — data-driven, no hardcoded IPs
  // in checks.rs. Phase 1: tiers (T0–T3 cadence + check-list) for the tiered
  // scan engine. Both are engine-owned configs read verbatim from inputs/.
  const resolvers = readInput("reports-resolvers.json");
  const tiers = readInput("reports-tiers.json");

  return {
    name: "build-reports.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json + 2_configs/src/inputs/reports-*.json via cloud-data-config-derive.ts/build-reports",
      _replaces: [
        "cloud-data-monitoring-targets.json",
        "cloud-data-topology.json",
        "cloud-data-databases.json",
        "cloud-data-dns-services.json",
        "cloud-data-url-health.json",
        "cloud-data-workflows.json",
        "cloud-data-repo-scan.json",
        "cloud-data-sec-scan.json",
      ],
      // Derived from consolidated
      endpoint_checks: endpointChecks,
      dns_checks: dnsChecks,
      tls_checks: tlsChecks,
      vms: vmList,
      services: servicesSummary,
      dns_services: dnsServices,
      databases: databases,
      topology: topology,
      // Embedded from engine-owned input configs
      url_health: urlHealth,
      workflows: workflows,
      repo_scan: repoScan,
      sec_scan: secScan,
      runtime_allowlist: runtimeAllowlist,
      resolvers: resolvers,
      tiers: tiers,
    },
  };
}

// Enterprise notification broker policy → dist/build-notify.json.
//
// Reads the engine-owned POLICY source (2_configs/src/inputs/notify-policy.json:
// severity map, routing table, dedup/flap/escalation/recovery, digest, status
// page schema) VERBATIM, then enriches it with the LIVE ntfy topic list from the
// consolidated file (configs.ntfy.topics — SoT is infra-obs_ntfy/build.json#topics).
// This lets the broker validate every routing topic against the real taxonomy and
// fail loud on drift, without duplicating the topic list. FIRE RULE 4 + 6: the
// policy is data, the broker is a dumb engine over it.
//
// Consumed by infra-obs_ntfy/src/code/notify-broker.py via the
// infra-obs_ntfy/src/build-notify.json symlink → 2_configs/dist/build-notify.json.
function deriveBuildNotify(c: any): DerivedFile {
  const ENGINE_DIR = import.meta.dirname!;
  const INPUTS_DIR = resolve(ENGINE_DIR, "../inputs");
  const policyPath = join(INPUTS_DIR, "notify-policy.json");

  let policy: any = {};
  if (existsSync(policyPath)) {
    try {
      policy = JSON.parse(readFileSync(policyPath, "utf-8"));
    } catch (e) {
      console.error(`[deriveBuildNotify] failed to parse ${policyPath}:`, e);
    }
  } else {
    console.error(`[deriveBuildNotify] policy input not found at ${policyPath} — emitting empty policy`);
  }

  // Live topic list from the ntfy taxonomy SoT (build.json → configs.ntfy.topics)
  // UNIONED with the generated RSS-channel topics (logs_*/app_*), else the broker
  // drops every log/app event as an "unknown topic" (notify-broker.py).
  const topicList: any[] = c.configs?.ntfy?.topics ?? [];
  const channelTopics = computeRssChannels(c).map((ch: any) => ch.topic);
  const validTopics = Array.from(new Set([...topicList.map((t: any) => t.name), ...channelTopics]));

  // Strip the leading _comment/_source scaffolding from the policy so the emitted
  // file's _meta block is the single source of provenance (engine adds _warning
  // + _meta.pipeline on write). Keep every functional block untouched.
  const { _comment, _source, ...functionalPolicy } = policy;

  return {
    name: "build-notify.json",
    data: {
      _meta: {
        description:
          "Notification broker policy (severity/routing/dedup/flap/escalation/recovery/digest/status). " +
          "Consumed by infra-obs_ntfy notify-broker.py.",
        format_version: 1,
      },
      _generated: now(),
      _source:
        "2_configs/src/inputs/notify-policy.json + _cloud-data-consolidated.json#configs.ntfy.topics " +
        "via cloud-data-config-derive.ts/build-notify",
      // Live taxonomy the broker validates routing topics against.
      valid_topics: validTopics,
      ...functionalPolicy,
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

// ── RSS channel taxonomy for the Cloud Mail SUPER RSS READER ────────────────
// Flat channel list (the app builds the folder tree by splitting `path` on "/").
// Fully derived from consolidated topology — counts are computed, never
// hardcoded (FIRE 4/6). Three sources:
//   - declared ntfy topics carry their own `path`/`title` (build.json) →
//     CICD / Security / Health / Ops / per-report channels;
//   - one `logs_<container>` channel per container of every ENABLED service;
//   - one `app_<service>` channel per user-app service (app|fin|mic|agi).
// Each leaf feed is served by the rss-gateway at /feed/c/<topic>.atom.
const RSS_APP_CATEGORIES = new Set(["app", "fin", "mic", "agi"]);

function computeRssChannels(c: any): any[] {
  const services = (c.services ?? {}) as Record<string, any>;
  const vms = (c.vms ?? {}) as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);
  const declared: any[] = c.configs?.ntfy?.topics ?? [];

  const channels: any[] = [];
  const seen = new Set<string>();
  const push = (ch: any) => {
    if (seen.has(ch.topic)) return; // topic == identity; never emit twice
    seen.add(ch.topic);
    channels.push(ch);
  };

  // 1) Declared topics → their path/title (skip the "all" universal pseudo-topic
  //    and any topic without a path — those are notify-only, not tree feeds).
  for (const t of declared) {
    if (t.name === "all" || !t.path) continue;
    push({
      id: t.name,
      topic: t.name,
      title: t.title ?? t.desc ?? t.name,
      path: `${t.path}/${t.name}`,
      category: t.category,
      source: "declared",
      feed: `/feed/c/${t.name}.atom`,
    });
  }

  // 2) Logs — one channel per container across every ENABLED service.
  for (const svc of Object.values(services)) {
    if (svc.enabled === false) continue;
    const alias = vmIdToAlias[svc.vm] ?? svc.vm;
    for (const cn of (svc.container_names ?? [])) {
      const topic = `logs_${cn}`;
      push({
        id: topic, topic,
        title: cn,
        path: `Cloud-Infra/Logs/${alias}/${cn}`,
        category: "logs", source: "logs", vm: alias,
        feed: `/feed/c/${topic}.atom`,
        quiet: true, // flipped off per-VM as the log tailer lands (phase 3)
      });
    }
  }

  // 3) Apps — one channel per user-app service.
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.enabled === false || !RSS_APP_CATEGORIES.has(svc.category)) continue;
    const topic = `app_${svcName}`;
    push({
      id: topic, topic,
      title: svc.description ?? svcName,
      path: `Cloud-Apps/${svc.category}/${svcName}`,
      category: "apps", source: "apps",
      feed: `/feed/c/${topic}.atom`,
      quiet: true, // no per-app publisher yet (phase 4)
    });
  }

  return channels;
}

function deriveNtfyRssChannels(c: any): DerivedFile {
  const channels = computeRssChannels(c);
  const domain = c.services?.ntfy?.dns?.domain ?? c.services?.ntfy?.domain ?? "rss.diegonmarcos.com";
  const counts = {
    declared: channels.filter((ch) => ch.source === "declared").length,
    logs: channels.filter((ch) => ch.source === "logs").length,
    apps: channels.filter((ch) => ch.source === "apps").length,
    total: channels.length,
  };
  return {
    name: "build-ntfy-rss-channels.json",
    data: {
      version: 1,
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/ntfy-rss-channels",
      base: `https://${domain}/feed`,
      counts,
      channels,
    },
  };
}

// Per-VM container manifest in the modern build-* family (lives at dist/ root).
// Replaces the deprecated cloud-data-containers-{alias}.json (which lives in
// dist/z_archive/ per the deprecation policy at the top of this file).
//
// Consumed by /opt/scripts/container-init.sh on each VM after it git-pulls
// cloud-data — it reads build-vm-{vm}.json to know which services to start.
function deriveBuildVm(c: any): DerivedFile[] {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const gha = c._gha ?? {};
  const ghaServices = gha.services ?? {};

  const files: DerivedFile[] = [];

  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    const alias = vm.ssh_alias;
    if (!alias) continue;

    const vmServices: any[] = [];
    for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
      if (svc.vm !== vmId) continue;

      const images: string[] = [];
      for (const ct of Object.values(svc.containers ?? {})) {
        const img = (ct as any).image;
        if (img && img !== "" && !img.endsWith(":local")) {
          images.push(img);
        }
      }

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

    // ssh_containers: derived in consolidation from per-service build.json
    // .ssh fields. Sliced here into per-VM build-vm-*.json so ssh-keys.nix
    // (in vm-pilot) can read the per-VM SSH-key deployment list directly.
    const hmVm = c._home_manager?.vms?.[alias] ?? {};
    const sshContainers = hmVm.ssh_containers ?? [];

    files.push({
      name: `build-vm-${alias}.json`,
      data: {
        vm: alias,
        vm_id: vmId,
        services: vmServices,
        ssh_containers: sshContainers,
      },
    });
  }

  return files;
}

// (deprecated deriveVmContainerManifests removed 2026-05-05 — replaced by deriveBuildVm above)

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

    // Surface extra_ports from container entries — needed by peers (e.g. cypht
    // referencing stalwart's 2443/2465/2587/2993). Shape: { <port>: <descriptor>, ... }
    // The `service` field is the declarative SoT for protocol-channel labels
    // (e.g. "imap_ssl", "jmap_tls", "smtp_starttls") — peers join against it.
    const extraPorts: Record<string, any> = {};
    for (const [role, ct] of Object.entries(svc.containers ?? {})) {
      for (const ep of ((ct as any).extra_ports ?? []) as any[]) {
        if (ep && typeof ep.port === "number") {
          extraPorts[String(ep.port)] = {
            protocol: ep.protocol ?? "tcp",
            bind:     ep.bind ?? null,
            desc:     ep.desc ?? null,
            ...(ep.service ? { service: ep.service } : {}),
            role,
          };
        }
      }
    }

    // Liveness probe target: app container's healthcheck path (fall back to any
    // container that declares one). Lets the c3-services-api /reach endpoint probe
    // ANY container, not just API/MCP services. null when none declared.
    const appHc =
      (svc.containers?.app?.healthcheck as string | undefined) ??
      (Object.values((svc.containers ?? {}) as Record<string, any>).find(
        (ct: any) => ct?.healthcheck,
      ) as any)?.healthcheck ??
      null;

    svcMap[svcName] = {
      ip: vmEntry.wg_ip,
      ports,
      vm: vmEntry.ssh_alias ?? svc.vm,
      ...(appHc ? { healthcheck: appHc } : {}),
      ...(svc.domain ? { domain: svc.domain } : {}),
      ...(svc.description ? { description: svc.description } : {}),
      ...(svc.api ? { api: svc.api } : {}),
      ...(svc.mcp ? { mcp: svc.mcp } : {}),
      // Cross-service declarative SoTs (each service's own build.json):
      ...(svc.users ? { users: svc.users } : {}),
      ...(svc.mail_clients ? { mail_clients: svc.mail_clients } : {}),
      ...(Object.keys(extraPorts).length > 0 ? { extra_ports: extraPorts } : {}),
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

// ═══════════════════════════════════════════════════════════════════════════
// KG-Graph derivers
//   - deriveKgSchema: emits SurrealDB schema spec (node/edge tables + vector
//     index declarations) from `c.services["kg-store"].kg`.
//   - deriveKgDelta:  emits an idempotent {nodes, edges} delta from the rest
//     of the consolidated file (vms, services, containers, dns, wireguard,
//     authelia ACL). Deterministic keys → re-running ingest is a no-op.
// Both files land at dist/build-kg-graph_*.json (NOT cloud-data-* — new
// pattern, not archived).
// ═══════════════════════════════════════════════════════════════════════════

function deriveKgSchema(c: any): DerivedFile {
  const kg = c.services?.["kg-store"]?.kg ?? {};
  const embedder = kg.embedder ?? { enabled: false, model: "nomic-embed-text", dim: 768, index_type: "MTREE", vector_dtype: "F32" };
  const nodeTables = kg.node_tables ?? [];
  const edgeTables = kg.edge_tables ?? [];

  // Vector indexes are only emitted when an embedder is declared+enabled.
  // This keeps MTREE creation declarative (Rule 3) and avoids wasting init
  // time on empty fields (matches the schema.surql.tpl Phase-3 comment).
  const vectorIndexes = embedder.enabled
    ? nodeTables
        .filter((n: any) => ["vm", "service", "container", "log", "documentation"].includes(n.table))
        .map((n: any) => ({
          name: `idx_${n.table}_embedding`,
          table: n.table,
          field: "embedding",
          type: embedder.index_type ?? "MTREE",
          dimension: embedder.dim ?? 768,
          dtype: embedder.vector_dtype ?? "F32",
        }))
    : [];

  return {
    name: "build-kg-graph_schema.json",
    data: {
      _meta: {
        description: "SurrealDB schema declaration for the kg-graph hybrid Knowledge Graph (node tables, edge relations, vector indexes). Consumed by ad-agi_kg-store at schema-load time and by reports-logs/kg_ingest at validation time.",
        format_version: 1,
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/kg-schema",
      namespace: kg.namespace ?? "infra",
      database: kg.database ?? "production",
      embedder,
      ingest: kg.ingest ?? { endpoint: "/import", idempotent: true },
      node_tables: nodeTables,
      edge_tables: edgeTables,
      vector_indexes: vectorIndexes,
    },
  };
}

function deriveKgDelta(c: any): DerivedFile {
  const services = (c.services ?? {}) as Record<string, any>;
  const vms = (c.vms ?? {}) as Record<string, any>;
  const dns = c.dns ?? {};
  const wg = c.native?.wireguard ?? c.wireguard ?? {};

  // Idempotent upsert keys: deterministic, never auto-generated.
  // SurrealDB record-id-safe form (replace "-" / "." with "_"; caller layer
  // is responsible for the surql ⟨…⟩ escape if it prefers raw).
  const safe = (s: string): string => s.replace(/[-.]/g, "_");
  const nodes: any[] = [];
  const edges: any[] = [];
  const seenNode = new Set<string>();
  const pushNode = (table: string, id: string, props: Record<string, any>) => {
    const key = `${table}:${id}`;
    if (seenNode.has(key)) return;
    seenNode.add(key);
    nodes.push({ table, id, key, properties: props });
  };
  const pushEdge = (table: string, fromKey: string, toKey: string, props: Record<string, any> = {}) => {
    edges.push({ table, from: fromKey, to: toKey, key: `${fromKey}->${table}->${toKey}`, properties: props });
  };

  // ── VM nodes ────────────────────────────────────────────────────────────
  for (const [vmId, vm] of Object.entries(vms)) {
    if (!vm.ssh_alias || !vm.wg_ip) continue;        // skip placeholders / TBD
    pushNode("vm", safe(vm.ssh_alias), {
      vm_id: vmId,
      alias: vm.ssh_alias,
      ip: vm.ip,
      wg_ip: vm.wg_ip,
      user: vm.user ?? null,
      provider: vm.provider ?? (vmId.startsWith("gcp") ? "gcp" : vmId.startsWith("oci") ? "oci" : null),
      arch: vm.specs?.arch ?? null,
      cpu_count: vm.specs?.cpu ?? null,
      ram_gb: vm.specs?.ram_gb ?? null,
      disk_gb: vm.specs?.disk_gb ?? null,
      description: vm.description ?? "",
    });
  }

  // ── Service + Container nodes (and runs_container, hosted_on edges) ─────
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.enabled === false) continue;             // honour build.json toggle
    const vmEntry = vms[svc.vm];
    const vmAlias = vmEntry?.ssh_alias;

    pushNode("service", safe(svcName), {
      name: svcName,
      category: svc.category ?? null,
      description: svc.description ?? "",
      domain: svc.domain ?? null,
      port: svc.port ?? null,
      vm: vmAlias ?? svc.vm,
      folder: svc.folder ?? null,
    });

    if (vmAlias) {
      pushEdge("hosted_on", `service:${safe(svcName)}`, `vm:${safe(vmAlias)}`);
    }

    for (const [role, ct] of Object.entries(svc.containers ?? {}) as [string, any][]) {
      const cname = ct.container_name || `${svcName}_${role}`;
      pushNode("container", safe(cname), {
        name: cname,
        image: ct.image ?? null,
        role,
        port: ct.port ?? null,
        public: ct.public ?? false,
      });
      pushEdge("runs_container", `service:${safe(svcName)}`, `container:${safe(cname)}`, { role });

      // depends_on edges from compose-level declarations
      for (const dep of (ct.depends_on ?? []) as string[]) {
        if (services[dep]) {
          pushEdge("depends_on", `service:${safe(svcName)}`, `service:${safe(dep)}`, { type: "runtime" });
        }
      }
    }
  }

  // ── connected_to (WG mesh) — declarative from native.wireguard.peers ────
  const peers: any[] = Array.isArray(wg.peers) ? wg.peers : Object.values(wg.peers ?? {});
  const aliases = peers.map((p: any) => p.alias).filter(Boolean);
  for (let i = 0; i < aliases.length; i++) {
    for (let j = i + 1; j < aliases.length; j++) {
      pushEdge("connected_to", `vm:${safe(aliases[i])}`, `vm:${safe(aliases[j])}`, { interface: "wg0" });
    }
  }

  // ── proxied_by — derived from services[].proxy.parent_domain ────────────
  const caddySvc = Object.entries(services).find(([, s]: [string, any]) =>
    s.category === "sec" && (s.folder ?? "").includes("caddy"));
  if (caddySvc) {
    const caddyKey = `service:${safe(caddySvc[0])}`;
    for (const [svcName, svc] of Object.entries(services)) {
      if (svcName === caddySvc[0]) continue;
      if (svc.proxy?.parent_domain || svc.domain) {
        pushEdge("proxied_by", `service:${safe(svcName)}`, caddyKey, {
          domain: svc.domain ?? svc.proxy?.parent_domain ?? null,
        });
      }
    }
  }

  // ── authenticated_by — reuse the ACL deriver as source of truth ─────────
  try {
    const acl = (deriveAutheliaAcl(c).data as any) ?? {};
    const aclRules = acl.rules ?? [];
    const autheliaSvc = Object.entries(services).find(([n]) => n === "authelia");
    if (autheliaSvc) {
      const autheliaKey = `service:${safe(autheliaSvc[0])}`;
      const seen = new Set<string>();
      for (const rule of aclRules) {
        const target = rule.service ?? rule.subject ?? null;
        if (!target || !services[target] || seen.has(target)) continue;
        seen.add(target);
        pushEdge("authenticated_by", `service:${safe(target)}`, autheliaKey);
      }
    }
  } catch { /* ACL deriver is best-effort here; missing → no auth edges. */ }

  // ── routes_to (Domain → Service) — from services[].domain + dns records ─
  for (const [svcName, svc] of Object.entries(services)) {
    if (!svc.domain) continue;
    pushNode("domain", safe(svc.domain), { fqdn: svc.domain });
    pushEdge("routes_to", `domain:${safe(svc.domain)}`, `service:${safe(svcName)}`);
  }
  for (const rec of (dns.records ?? [])) {
    if (!rec?.name || rec.type !== "CNAME") continue;
    pushNode("domain", safe(rec.name), { fqdn: rec.name, type: rec.type, value: rec.value ?? null });
  }

  // ── CODE GRAPH — repo / module / package nodes + code-relationship edges ──
  // Bridges the running-infra graph (service/vm/container) to the source-code
  // structure that produces it. 100% derived from declared data — never typed
  // by hand (Rule 6). Front/unix/tools *internal* module graphs land here once
  // those repos feed their own structure into the pipeline (front-deps.json,
  // flake parsers); today the cloud repo is fully covered + cross-repo edges.
  pushNode("repo", "cloud", { name: "cloud", role: "service-infra" });

  // module nodes — one per enabled service's a_solutions folder; bridge edges
  // implements (module→service) + belongs_to_repo (module→repo:cloud).
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.enabled === false || !svc.folder) continue;
    const modId = safe(svc.folder);
    pushNode("module", modId, {
      name: svc.folder,
      repo: "cloud",
      category: svc.category ?? null,
      service: svcName,
    });
    pushEdge("belongs_to_repo", `module:${modId}`, "repo:cloud");
    pushEdge("implements", `module:${modId}`, `service:${safe(svcName)}`);
  }

  // package nodes + declares_tool — from the consolidated tooling registry
  // (c.deps groups: system/build/optional/node/install/gha).
  for (const [group, entries] of Object.entries((c.deps ?? {}) as Record<string, any>)) {
    if (!entries || typeof entries !== "object") continue;
    for (const [pkgName, pkg] of Object.entries(entries as Record<string, any>)) {
      const pkgId = safe(pkgName);
      pushNode("package", pkgId, {
        name: pkgName,
        group,
        nix: pkg?.nix ?? null,
        apt: pkg?.apt ?? null,
        description: pkg?.desc ?? null,
      });
      pushEdge("declares_tool", "repo:cloud", `package:${pkgId}`, { group });
    }
  }

  // consumes edges — cross-repo, from the external-consumers registry. A
  // consumer in unix/ or cloud-data/ that reads a slice of the consolidated
  // file is a downstream repo that `consumes` the cloud repo.
  try {
    const REGISTRY = join(CONFIGS_DIR, "src", "external-consumers.json");
    if (existsSync(REGISTRY)) {
      const reg = JSON.parse(readFileSync(REGISTRY, "utf-8"));
      const repoOf = (p: string): string => (/(?:^|\/)git\/([^/]+)/.exec(p ?? "")?.[1]) ?? "";
      for (const consumer of (reg.consumers ?? []) as any[]) {
        const repo = repoOf(consumer.consumer_path ?? "");
        if (!repo || repo === "cloud") continue;
        pushNode("repo", safe(repo), { name: repo });
        pushEdge("consumes", `repo:${safe(repo)}`, "repo:cloud", {
          consumer: consumer.name ?? null,
          via: "cloud-data slice",
        });
      }
    }
  } catch { /* registry best-effort; missing → no cross-repo edges. */ }

  return {
    name: "build-kg-graph_delta.json",
    data: {
      _meta: {
        description: "Idempotent delta for the kg-graph SurrealDB instance. Re-applying the same delta is a no-op (deterministic keys + UPSERT MERGE on the consumer side).",
        format_version: 1,
        idempotency: {
          node_key: "<table>:<sanitized_id>",
          edge_key: "<from_key>-><table>-><to_key>",
          stale_strategy: "mark with last_seen_ts (never hard-delete)",
        },
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via cloud-data-config-derive.ts/kg-delta",
      counts: {
        nodes: nodes.length,
        edges: edges.length,
        by_table: nodes.reduce((acc: Record<string, number>, n: any) => {
          acc[n.table] = (acc[n.table] ?? 0) + 1; return acc;
        }, {}),
      },
      nodes,
      edges,
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// deriveCloudFleetDeclared — dist/cloud-fleet-containers-declared.json
//
// Wide fleet snapshot: every declared container/service with Fleet grouping
// (Infra-Apps / User-Apps / DB / VMs / Providers) and cross-cut Categories
// (APIs, MCPs, Runners, db-Dockers, db-S3, db-HD, mesh-peers).
//
// This file is the source of truth for fleet display in cloud-superapp,
// linktree, front portals, and admin panels — replace all local hardcoded
// service lists with a fetch of this file.
// ═══════════════════════════════════════════════════════════════════════════

/** Map consolidated `category` → Fleet group + subcategory (subgroup label). */
const CATEGORY_TO_FLEET: Record<string, { group: "infra-apps" | "user-apps"; subgroup: string }> = {
  // Infra
  "sec":       { group: "infra-apps", subgroup: "Security" },
  "net":       { group: "infra-apps", subgroup: "Network" },
  "infra-net": { group: "infra-apps", subgroup: "Network" },
  "obs":       { group: "infra-apps", subgroup: "Observability" },
  "cloud":     { group: "infra-apps", subgroup: "APIs-MCPs" },
  // User
  "app":       { group: "user-apps",  subgroup: "Productivity" },
  "agi":       { group: "user-apps",  subgroup: "AI-Agents" },
  "mic":       { group: "user-apps",  subgroup: "Communications" },
  "fin":       { group: "user-apps",  subgroup: "Finance" },
};

/** Per-service subgroup overrides (takes precedence over CATEGORY_TO_FLEET). */
const SERVICE_SUBGROUP_OVERRIDE: Record<string, { group: "infra-apps" | "user-apps"; subgroup: string }> = {
  // tools → differentiate by function
  "dagu":                   { group: "infra-apps", subgroup: "Observability" },
  "dbgate":                 { group: "infra-apps", subgroup: "Observability" },
  "matomo":                 { group: "infra-apps", subgroup: "Observability" },
  "umami":                  { group: "infra-apps", subgroup: "Observability" },
  "openobserve":            { group: "infra-apps", subgroup: "Observability" },
  "ntfy":                   { group: "infra-apps", subgroup: "Observability" },
  "cloud-spec":             { group: "infra-apps", subgroup: "APIs-MCPs" },
  "cloud-builder-x":        { group: "infra-apps", subgroup: "Build" },
  "gha-runner":             { group: "infra-apps", subgroup: "Build" },
  "news-gdelt":             { group: "infra-apps", subgroup: "Data" },
  "wireguard-mesh":         { group: "infra-apps", subgroup: "Network" },
  "wireguard-mesh-ws-tunnel": { group: "infra-apps", subgroup: "Network" },
  "wireguard-public":       { group: "infra-apps", subgroup: "Network" },
  "hickory-dns":            { group: "infra-apps", subgroup: "Network" },
  "alerts-api":             { group: "infra-apps", subgroup: "Observability" },
  "languagetool":           { group: "infra-apps", subgroup: "APIs-MCPs" },
  "postlite":               { group: "infra-apps", subgroup: "Data" },
  "redis":                  { group: "infra-apps", subgroup: "Data" },
  // data → split: gitea/backups=Data, rest=APIs-MCPs
  "gitea":                  { group: "infra-apps", subgroup: "Data" },
  "backup-borg":            { group: "infra-apps", subgroup: "Data" },
  "backup-bup":             { group: "infra-apps", subgroup: "Data" },
  "db-agent":               { group: "infra-apps", subgroup: "Data" },
  "kg-store":               { group: "infra-apps", subgroup: "Data" },
  "scrappers-api":          { group: "infra-apps", subgroup: "APIs-MCPs" },
  "c3-diego-personal-data-mcp": { group: "infra-apps", subgroup: "APIs-MCPs" },
  "c3-infra-api":           { group: "infra-apps", subgroup: "APIs-MCPs" },
  "c3-infra-mcp":           { group: "infra-apps", subgroup: "APIs-MCPs" },
  "c3-public-api":          { group: "infra-apps", subgroup: "APIs-MCPs" },
  "c3-services-api":        { group: "infra-apps", subgroup: "APIs-MCPs" },
  "c3-services-mcp":        { group: "infra-apps", subgroup: "APIs-MCPs" },
  "cloud-cgc-mcp":          { group: "infra-apps", subgroup: "APIs-MCPs" },
  // app → subgroup by domain/function
  "chat-mattermost":        { group: "user-apps",  subgroup: "Communications" },
  "matrix-element":         { group: "user-apps",  subgroup: "Communications" },
  "matrix-mautrix-whatsapp": { group: "user-apps", subgroup: "Communications" },
  "matrix-continuwuity":    { group: "user-apps",  subgroup: "Communications" },
  "snappymail":             { group: "user-apps",  subgroup: "Communications" },
  "maddy":                  { group: "user-apps",  subgroup: "Communications" },
  "stalwart":               { group: "user-apps",  subgroup: "Communications" },
  "mail-puller":            { group: "user-apps",  subgroup: "Communications" },
  "http-to-smtp-proxy-api": { group: "user-apps",  subgroup: "Communications" },
  "google-personal-mcp":    { group: "user-apps",  subgroup: "AI-Agents" },
  "google-workspace-mcp":   { group: "user-apps",  subgroup: "AI-Agents" },
  "mail-mcp":               { group: "user-apps",  subgroup: "AI-Agents" },
  "mattermost-mcp":         { group: "user-apps",  subgroup: "AI-Agents" },
  "claude-superset-api":    { group: "user-apps",  subgroup: "AI-Agents" },
  "hermes-agent":           { group: "user-apps",  subgroup: "AI-Agents" },
  "my-ai-api":              { group: "user-apps",  subgroup: "AI-Agents" },
  "session-memory":         { group: "user-apps",  subgroup: "AI-Agents" },
  "photoprism":             { group: "user-apps",  subgroup: "Media" },
  "vaultwarden":            { group: "user-apps",  subgroup: "Vault" },
  "calendar-radicale":      { group: "user-apps",  subgroup: "Productivity" },
  "contacts-radicale":      { group: "user-apps",  subgroup: "Productivity" },
  "etherpad":               { group: "user-apps",  subgroup: "Productivity" },
  "hedgedoc":               { group: "user-apps",  subgroup: "Productivity" },
  "grist":                  { group: "user-apps",  subgroup: "Productivity" },
  "filebrowser":            { group: "user-apps",  subgroup: "Productivity" },
  "code-server":            { group: "user-apps",  subgroup: "Productivity" },
  "revealmd":               { group: "user-apps",  subgroup: "Productivity" },
  "send":                   { group: "user-apps",  subgroup: "Productivity" },
  "paca":                   { group: "user-apps",  subgroup: "Productivity" },
  "fin-api":                { group: "user-apps",  subgroup: "Finance" },
};

const RUNNER_SERVICES = new Set(["gha-runner", "cloud-builder-x", "dagu"]);

function deriveCloudFleetDeclared(c: any): DerivedFile {
  const services: Record<string, any> = c.services ?? {};
  const vms: Record<string, any>      = c.vms ?? {};
  const vpss: Record<string, any>     = c.vpss ?? {};
  const storage: any[]                = Array.isArray(c.storage) ? c.storage : [];

  // ── Build service entry ──────────────────────────────────────────────────
  function svcEntry(id: string, svc: any) {
    const domain: string = svc.domain ?? "";
    return {
      id,
      name:        svc.name ?? id,
      vm:          svc.vm ?? null,
      category:    svc.category ?? null,
      subgroup:    (SERVICE_SUBGROUP_OVERRIDE[id] ?? CATEGORY_TO_FLEET[svc.category ?? ""])?.subgroup ?? null,
      port:        svc.port ?? null,
      private_ip:  (vms[svc.vm ?? ""] ?? {}).wg_ip ?? null,
      private_url: svc.port ? `https://${id}.app` : null,
      public_url:  domain ? `https://${domain}` : null,
      mcp:         svc.mcp ? true : undefined,
    };
  }

  // ── Fleet.Containers ────────────────────────────────────────────────────
  const infraApps: any[] = [];
  const userApps:  any[] = [];

  for (const [id, svc] of Object.entries(services)) {
    if ((svc as any).vm === "local" && !(svc as any).domain) continue; // skip pure local/virtual entries
    const mapping = SERVICE_SUBGROUP_OVERRIDE[id] ?? CATEGORY_TO_FLEET[(svc as any).category ?? ""];
    if (!mapping) continue; // cloudflare-worker, front-end, db-agent(all) — skip unclassified
    const entry = svcEntry(id, svc as any);
    if (mapping.group === "infra-apps") infraApps.push(entry);
    else userApps.push(entry);
  }

  // ── Fleet.DB ─────────────────────────────────────────────────────────────
  const dbS3 = storage.map((s: any) => ({
    id:       s.name ?? s.dns,
    name:     s.name ?? null,
    dns:      s.dns ?? null,
    region:   s.region ?? null,
    provider: s.provider ?? null,
    endpoint: s.s3_endpoint ?? null,
  }));

  const dbHd: any[] = [];
  for (const [svcId, svc] of Object.entries(services)) {
    for (const [ctName, ct] of Object.entries((svc as any).containers ?? {})) {
      const engine = (ct as any).db_engine;
      if (!engine) continue;
      dbHd.push({ id: `${svcId}/${ctName}`, service: svcId, container: ctName, engine });
    }
  }

  // ── Fleet.VMs ─────────────────────────────────────────────────────────────
  const vmX86: any[] = [];
  const vmArm: any[] = [];
  for (const [vmId, vm] of Object.entries(vms)) {
    const entry = {
      id:      vmId,
      alias:   (vm as any).ssh_alias ?? vmId,
      arch:    (vm as any).specs?.arch ?? null,
      wg_ip:   (vm as any).wg?.ip ?? null,
      provider: (vm as any).specs?.shape?.split(".")?.[0] ?? null,
    };
    if ((vm as any).specs?.arch === "aarch64") vmArm.push(entry);
    else vmX86.push(entry);
  }

  // ── Fleet.Providers ───────────────────────────────────────────────────────
  const providers = Object.entries(vpss).map(([id, vps]) => ({
    id,
    provider:        (vps as any).provider ?? id,
    tier:            (vps as any).tier ?? null,
    infrastructure:  (vps as any).infrastructure_type ?? null,
    has_terraform:   (vps as any).has_terraform ?? false,
  }));

  // ── Categories (cross-cut) ─────────────────────────────────────────────
  const allContainers = [...infraApps, ...userApps];
  const categories = {
    runners:     allContainers.filter(e => RUNNER_SERVICES.has(e.id)),
    apis:        allContainers.filter(e => e.public_url && !e.mcp),
    mcps:        allContainers.filter(e => e.mcp),
    "db-dockers": dbHd,
    "db-s3":     dbS3,
    "db-hd":     dbHd.filter(e => ["postgres", "mariadb", "surrealdb"].includes(e.engine)),
    "mesh-peers": [...vmX86, ...vmArm],
  };

  return {
    name: "cloud-fleet-containers-declared.json",
    data: {
      _meta: {
        description: "Declared cloud fleet — containers, VMs, storage, providers. Source of truth for all fleet display frontends.",
        source_inputs: ["_cloud-data-consolidated.json"],
        generated_by:  "cloud-data-config-derive.ts/cloud-fleet-containers-declared",
      },
      fleet: {
        containers: {
          "infra-apps": infraApps,
          "user-apps":  userApps,
        },
        db: {
          "db-s3": dbS3,
          "db-hd": dbHd,
        },
        vms: {
          "vm-x86": vmX86,
          "vm-arm": vmArm,
        },
        providers,
      },
      categories,
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// deriveCloudFleetMerged — dist/cloud-fleet-declared.json
//
// Full fleet snapshot: cloud containers + GH Pages front projects merged.
// Reads the two sibling files just emitted in this run.
// ═══════════════════════════════════════════════════════════════════════════
function deriveCloudFleetMerged(): DerivedFile {
  const containersSrc = join(CLOUD_DATA_DIR, "cloud-fleet-containers-declared.json");
  const frontSrc      = join(GIT_BASE, "front", "2_configs", "dist", "front-fleet-gh-declared.json");

  const containers = existsSync(containersSrc)
    ? JSON.parse(readFileSync(containersSrc, "utf8"))
    : null;

  const frontPages = existsSync(frontSrc)
    ? JSON.parse(readFileSync(frontSrc, "utf8"))
    : [];

  return {
    name: "cloud-fleet-declared.json",
    data: {
      _meta: {
        description: "Full declared fleet — cloud containers + GH Pages front projects. Source of truth for all fleet display.",
        source_inputs: [
          "2_configs/dist/cloud-fleet-containers-declared.json",
          "front/2_configs/dist/front-fleet-gh-declared.json",
        ],
        generated_by: "cloud-data-config-derive.ts/cloud-fleet-declared",
      },
      cloud:       containers ?? {},
      front_pages: frontPages,
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

  // Run all derivations
  const derived: DerivedFile[] = [
    ...deriveBuildVm(consolidated),                  // dist/build-vm-{vm}.json — per-VM service manifest
    deriveServiceConnections(consolidated),
    deriveDnsServices(consolidated),
    ...deriveCaddy(consolidated),
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
    deriveBuildNotify(consolidated),        // dist/build-notify.json — notification broker policy
    deriveBackupTargets(consolidated),
    deriveContainerResources(consolidated),
    deriveLogRouting(consolidated),
    deriveCloudflareDns(consolidated),
    deriveMatomoSites(consolidated),
    deriveNtfyAcl(consolidated),
    deriveNtfyRssChannels(consolidated), // dist/build-ntfy-rss-channels.json — Cloud Mail RSS tree
    deriveTopology(consolidated),
    deriveConfigs(consolidated),
    deriveDeps(consolidated),
    deriveDatabases(consolidated),
    deriveSecretsEnvVarNames(consolidated),
    deriveKgSchema(consolidated),
    deriveKgDelta(consolidated),
    ...deriveExternalConsumers(consolidated),
    deriveCloudFleetDeclared(consolidated),     // dist/cloud-fleet-containers-declared.json
    deriveCloudFleetMerged(),                   // dist/cloud-fleet-declared.json
  ];

  // Write all files (inject the rich DO NOT EDIT header + pipeline metadata into each).
  //
  // Every emitted file gets two top-level fields:
  //   _warning : single-line "DO NOT EDIT" message that even raw-text consumers see.
  //   _meta.pipeline : full pipeline description — engine paths, source inputs,
  //                    output locations, and the rebuild command. Mirrors the
  //                    block emitted by cloud-data-config-consolidated.ts so any
  //                    consumer reading either the master or a derived file can
  //                    trace back to the source-of-truth in one read.
  const DO_NOT_EDIT = "DO NOT EDIT — AUTO-GENERATED FILE. Source of truth lives in a_solutions/*/build.json + config.json + b_infra/*/build.json. Edits here are overwritten on every `bash 2_configs/build.sh all`.";
  const PIPELINE_META = {
    description: "Two-stage build: consolidator merges all build.json + config.json sources into the master file; derive emits per-container + archived split files from the master.",
    source_inputs: [
      "a_solutions/*/build.json (per-service declarations)",
      "config.json (global topology + vms + dns + wireguard)",
      "b_infra/*/build.json (per-VM HM config)",
      "vault/secrets.yaml (sops-encrypted secrets per service, key names extracted)",
    ],
    engines: {
      consolidator: "2_configs/src/engines/cloud-data-config-consolidated.ts",
      derive: "2_configs/src/engines/cloud-data-config-derive.ts (THIS engine)",
    },
    outputs: {
      master: "2_configs/dist/_cloud-data-consolidated.json (consolidator output)",
      per_container: "2_configs/dist/build-{container_or_service_name}.json (one per container, plus one per container-less service — derive output)",
      archived: "2_configs/dist/z_archive/cloud-data-{slice}.json (deprecated split files — kept for soft-transition fallbacks; consumers should read consolidated instead)",
    },
    rebuild_command: "bash 2_configs/build.sh all",
  };
  const summary: string[] = [];
  for (const file of derived) {
    const path = join(targetDirFor(file.name), file.name);
    let output: any = file.data;
    if (typeof file.data === "object" && !Array.isArray(file.data)) {
      // Splice the rich pipeline metadata into the file's existing _meta block
      // (most derive functions already set _meta.description, format_version).
      const data = file.data as any;
      const existingMeta = (data._meta && typeof data._meta === "object") ? data._meta : {};
      output = {
        _warning: DO_NOT_EDIT,
        ...data,
        _meta: {
          ...existingMeta,
          generated_at: existingMeta.generated_at ?? now(),
          generated_by: "2_configs/src/engines/cloud-data-config-derive.ts",
          pipeline: PIPELINE_META,
        },
      };
    }
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
