// derive-mesh-snapshot.ts
//
// Reads the canonical post-restructure SoT and emits a single flat snapshot
// consumed by bb-net_wireguard-mesh as PORTAL_DATA["mesh"].
//
// Inputs (read-only, single source of truth):
//   - 1_cloud-configs/dist/_cloud-data-consolidated.json  ← VMs (ip, wg_ip, wg_role,
//                                                     wg_public_key, wg_port,
//                                                     ssh_alias, public_ports)
//   - a_solutions/infra-net_wireguard-mesh-ws-tunnel/build.json  ← transport
//                                                     declarations (UDP + TCP/443)
//   - c_vps/ba-clo_cloudflare/src/terraform.json  ← the public zone (A/AAAA
//                                                     answers pinned in .bootstrap)
//
// Output:
//   - 1_cloud-configs/dist/mesh-snapshot.json   (schema: wg-mesh/v1)
//
// Per fire-rule 6: NO hardcoded node lists / IPs / endpoints. Every value
// in the output is computed from the input files. Adding a peer to consolidated
// data automatically appears in the panel on the next deploy.
//
// Per the dist/ convention enforced by cloud-data-config-derive.ts (L26-30):
// only "cloud-data-*" files go to z_archive/; this output uses the bare
// "mesh-snapshot.json" name and lives at dist/ root.

import * as fs from 'node:fs';
import * as path from 'node:path';

// ── repo-root resolution (mirrors cloud-data-config-derive.ts pattern) ────
const ENGINE_DIR  = import.meta.dirname!;
const CONFIGS_DIR = path.resolve(ENGINE_DIR, '..', '..');
const CLOUD_ROOT  = process.env.CLOUD_ROOT ?? path.resolve(CONFIGS_DIR, '..');
const DIST_DIR    = path.join(CONFIGS_DIR, 'dist');

const READ = (rel: string): unknown =>
  JSON.parse(fs.readFileSync(path.join(CLOUD_ROOT, rel), 'utf8'));

// ── Output types (mirror src/typescript/modules/types.ts in the panel) ────
type NodeRole = 'hub' | 'spoke' | 'client';
interface Node {
  name: string; role: NodeRole; alias?: string;
  public_ip: string; wg_ip: string; region: string; provider: string; os: string;
  public_key_fp?: string; ports_public?: (string | number)[];
  wstunnel_server?: boolean; wstunnel_client?: boolean;
}
interface Peer { from: string; to: string; allowed_ips: string[]; persistent_keepalive: number }
interface Transport {
  name: string; label: string; protocol: 'udp' | 'tcp'; port: number;
  endpoint: string; primary: boolean; fallback: boolean;
  active_peers?: number; use_case?: string;
}
interface Route { src_node: string; dst_subnet: string; via_transport: string; comment?: string }
interface TlsExpiry { host: string; expires_at: string; issuer?: string }
// The mesh BOOTSTRAP: what a client needs to reach the hubs and the TCP/443
// relay WITHOUT asking the local network's DNS (public Wi-Fi that blocks or
// hijacks port 53). Every value is computed from the Cloudflare zone
// declaration, the ws-tunnel build.json and the consolidated VMs.
interface PinnedHost { host: string; v4: string[]; v6: string[]; role: string; record: string }
interface Hub { name: string; mesh: string; public_key: string; endpoints: string[] }
interface RelayRoute { remote: string; hub: string; mesh: string; public_key: string }
interface Bootstrap {
  _doc: string;
  sources: { zone: string; ws_tunnel: string; consolidated: string };
  zone: string;
  pinned_hosts: PinnedHost[];
  hubs: Hub[];
  relay: { host: string; port: number; scheme: string; path: string; prefix_secret: string; routes: RelayRoute[] } | null;
  etc_hosts: string[];
}
interface Snapshot {
  _meta: { generated_at: string; generated_by: string; schema: string;
           sources: { consolidated: string; ws_tunnel: string } };
  nodes: Node[]; peers: Peer[]; transports: Transport[]; routes: Route[];
  health: { tls_expiries: TlsExpiry[]; last_snapshot_at: string; status: 'healthy' | 'degraded' | 'down' };
  bootstrap: Bootstrap;
}

// ── Helpers ───────────────────────────────────────────────────────────────
function shortKey(pubkey: string | undefined): string | undefined {
  if (!pubkey) return undefined;
  if (pubkey.length <= 10) return pubkey;
  return pubkey.slice(0, 5) + '…' + pubkey.slice(-4);
}

function providerOf(vmId: string): string {
  if (vmId.startsWith('gcp-')) return 'gcloud';
  if (vmId.startsWith('oci-')) return 'oci';
  if (vmId.startsWith('aws-')) return 'aws';
  if (vmId.startsWith('hetzner-')) return 'hetzner';
  if (vmId.startsWith('vast-')) return 'vast';
  return 'personal';
}

/**
 * The public A/AAAA answer Cloudflare gives for [host], from the zone's own
 * declaration (c_vps/ba-clo_cloudflare/src/terraform.json), with the rules
 * main.tf applies: an exact a_record wins over the '*' wildcard, a record's
 * `ip` overrides proxy_ip, `extra_ips` add v4 values, and the AAAA twin is the
 * record's `ip6`, else proxy_ip6 unless `ip` was overridden.
 */
export function zoneAnswer(zone: any, host: string): { v4: string[]; v6: string[]; record: string } | null {
  const domain = String(zone?.domain ?? '');
  if (!domain || !(host === domain || host.endsWith('.' + domain))) return null;
  const label = host === domain ? domain : host.slice(0, -(domain.length + 1));
  const recs: any[] = zone?.dns_records?.a_records ?? [];
  const rec = recs.find(r => r.name === label || r.name === host) ?? recs.find(r => r.name === '*');
  if (!rec) return null;
  const v4 = [String(rec.ip ?? zone.proxy_ip ?? ''), ...((rec.extra_ips ?? []) as unknown[]).map(String)].filter(Boolean);
  const v6 = rec.ip6 ? [String(rec.ip6)] : (rec.ip == null && zone.proxy_ip6 ? [String(zone.proxy_ip6)] : []);
  return { v4, v6, record: String(rec.name) };
}

/** The `--restrict-to host:port` targets of the wstunnel server's command line. */
function restrictTargets(wsTunnel: any): string[] {
  const cmd: unknown[] = wsTunnel?.containers?.app?.command ?? [];
  const out: string[] = [];
  cmd.forEach((a, i) => { if (a === '--restrict-to' && typeof cmd[i + 1] === 'string') out.push(String(cmd[i + 1])); });
  return out;
}

export function buildBootstrap(consolidated: any, wsTunnel: any, zone: any, rels: Bootstrap['sources']): Bootstrap {
  const vms: Record<string, any> = consolidated?.vms ?? {};
  const hubVm = Object.values(vms).find((v: any) => v?.wg_role === 'hub') as any;
  const hubs: Hub[] = [];
  if (hubVm?.ip && hubVm?.wg_public_key) {
    hubs.push({ name: String(hubVm.ssh_alias ?? ''), mesh: 'wg0', public_key: String(hubVm.wg_public_key),
                endpoints: [`${hubVm.ip}:${hubVm.wg_port ?? 51820}`] });
  }
  const wp = consolidated?.wireguard_public;
  const wpHub = (wp?.peers ?? []).find((p: any) => p?.role === 'hub');
  if (wpHub?.endpoint && wpHub?.wg_public_key) {
    hubs.push({ name: String(wpHub.name), mesh: 'wg-public', public_key: String(wpHub.wg_public_key), endpoints: [String(wpHub.endpoint)] });
  }

  const relayHost: string = String(wsTunnel?.domain ?? '');
  const relayVm = Object.values(vms).find((v: any) => v?.ssh_alias === wsTunnel?.deploy?.host) as any;
  const tcp = wsTunnel?.transports?.['wg0-tcp'];
  const routes: RelayRoute[] = [];
  for (const t of restrictTargets(wsTunnel)) {
    const i = t.lastIndexOf(':');
    const ip = t.slice(0, i), port = t.slice(i + 1);
    // A loopback target is the relay host's OWN listener; anything else is a hub endpoint as declared.
    const ep = (ip === '127.0.0.1' || ip === '::1') && relayVm?.ip ? `${relayVm.ip}:${port}` : t;
    const hub = hubs.find(h => h.endpoints.includes(ep));
    if (hub) routes.push({ remote: t, hub: hub.name, mesh: hub.mesh, public_key: hub.public_key });
  }
  const relay = relayHost && tcp ? {
    host: relayHost,
    port: Number(tcp.port ?? 443),
    scheme: 'wss',
    // wstunnel v11 upgrades at /<path prefix>/events (tunnel/transport/websocket.rs).
    path: '/{prefix}/events',
    prefix_secret: String(tcp.wstunnel_path_prefix_secret ?? ''),
    routes,
  } : null;

  const pinned: PinnedHost[] = [];
  if (relayHost) {
    const a = zoneAnswer(zone, relayHost);
    if (a) pinned.push({ host: relayHost, v4: a.v4, v6: a.v6, role: 'relay', record: a.record });
  }
  return {
    _doc: "Mesh bootstrap: what a client needs to reach the hubs and the TCP/443 relay without the local network's DNS (public Wi-Fi that blocks or hijacks port 53). pinned_hosts are the public answers the zone declares, a hosts-file equivalent (the SuperApp pins them, Linux renders etc_hosts); hubs are the WireGuard hubs by public key; relay is the wstunnel server and routes are its --restrict-to targets matched to the hub each reaches. The path prefix is a secret: only its name travels here.",
    sources: rels,
    zone: String(zone?.domain ?? ''),
    pinned_hosts: pinned,
    hubs,
    relay,
    etc_hosts: pinned.flatMap(p => [...p.v4, ...p.v6].map(ip => `${ip} ${p.host}`)),
  };
}

// ── Build the snapshot ────────────────────────────────────────────────────
export function build(): Snapshot {
  const consolidatedRel = '1_cloud-configs/dist/_cloud-data-consolidated.json';
  const wsTunnelRel     = 'a_solutions/infra-net_wireguard-mesh-ws-tunnel/build.json';
  const zoneRel         = 'c_vps/ba-clo_cloudflare/src/terraform.json';

  const consolidated = READ(consolidatedRel) as any;
  const wsTunnel     = (() => {
    try { return READ(wsTunnelRel) as any; }
    catch { return null; }   // ws-tunnel sibling may be in a transitional state
  })();

  const vms: Record<string, any> = consolidated?.vms ?? {};

  // Hub election: explicit wg_role === 'hub' wins; else the gcp-proxy ssh_alias.
  let hubVmId: string | null = null;
  for (const [vmId, vm] of Object.entries(vms)) {
    if ((vm as any)?.wg_role === 'hub') { hubVmId = vmId; break; }
  }
  if (!hubVmId) {
    for (const [vmId, vm] of Object.entries(vms)) {
      if ((vm as any)?.ssh_alias === 'gcp-proxy') { hubVmId = vmId; break; }
    }
  }

  const wsTunnelHost = wsTunnel?.deploy?.host ?? null;   // ssh_alias

  const nodes: Node[] = Object.entries(vms).map(([vmId, vm]: [string, any]) => {
    const isHub = vmId === hubVmId;
    const role: NodeRole =
      isHub ? 'hub' :
      (vm.wg_role === 'client' || vm.kind === 'mobile') ? 'client' :
      'spoke';
    return {
      name:          vmId,
      role,
      alias:         vm.ssh_alias,
      public_ip:     String(vm.ip ?? ''),
      wg_ip:         String(vm.wg_ip ?? ''),
      region:        String(vm.specs?.cloud_zone ?? vm.region ?? '?'),
      provider:      providerOf(vmId),
      os:            String(vm.os ?? 'NixOS'),
      public_key_fp: shortKey(vm.wg_public_key),
      ports_public:  Array.isArray(vm.public_ports) ? vm.public_ports : [],
      wstunnel_server: wsTunnelHost != null && vm.ssh_alias === wsTunnelHost,
      wstunnel_client: role === 'client',
    };
  });

  // Hub-and-spoke peer edges derived from consolidated VM list
  const hub = nodes.find(n => n.role === 'hub');
  const peers: Peer[] = [];
  if (hub) {
    for (const n of nodes) {
      if (n.name === hub.name) continue;
      peers.push({ from: hub.name, to: n.name, allowed_ips: [`${n.wg_ip}/32`], persistent_keepalive: 25 });
      peers.push({ from: n.name,   to: hub.name, allowed_ips: ['10.0.0.0/24'],     persistent_keepalive: 25 });
    }
  }

  // Transports — pull from ws-tunnel sibling build.json (SoT for the VPN itself)
  const transports: Transport[] = [];
  const vpnT = wsTunnel?.transports;
  const wstunnelClients = nodes.filter(n => n.wstunnel_client).length;

  if (vpnT?.wg0) {
    transports.push({
      name:        'wg0',
      label:       String(vpnT.wg0.label ?? 'WireGuard direct (UDP)'),
      protocol:    'udp',
      port:        Number(vpnT.wg0.port ?? 51820),
      endpoint:    String(vpnT.wg0.endpoint ?? `${hub?.public_ip ?? ''}:51820`),
      primary:     !!vpnT.wg0.primary,
      fallback:    !!vpnT.wg0.fallback,
      active_peers: nodes.length - 1,
      use_case:    'Default high-speed path. UDP-friendly networks.',
    });
  } else {
    transports.push({
      name: 'wg0', label: 'WireGuard direct (UDP)', protocol: 'udp', port: 51820,
      endpoint: `${hub?.public_ip ?? ''}:51820`, primary: true, fallback: false,
      active_peers: nodes.length - 1,
      use_case: 'Default high-speed path. UDP-friendly networks.',
    });
  }

  if (vpnT?.['wg0-tcp']) {
    transports.push({
      name:        'wg0-tcp',
      label:       String(vpnT['wg0-tcp'].label ?? 'WireGuard via wstunnel (TCP/443)'),
      protocol:    'tcp',
      port:        Number(vpnT['wg0-tcp'].port ?? 443),
      endpoint:    String(vpnT['wg0-tcp'].endpoint ?? ''),
      primary:     !!vpnT['wg0-tcp'].primary,
      fallback:    !!vpnT['wg0-tcp'].fallback,
      active_peers: wstunnelClients,
      use_case:    'Hostile networks (airport, hotel) where UDP/51820 is blocked.',
    });
  }

  // Routes derived from peers + transports
  const routes: Route[] = [];
  for (const n of nodes) {
    if (n.role === 'hub') continue;
    routes.push({
      src_node:      n.name,
      dst_subnet:    '10.0.0.0/24',
      via_transport: 'wg0',
      comment:       n.role === 'client' ? 'default UDP path' : undefined,
    });
    if (n.wstunnel_client && transports.find(t => t.name === 'wg0-tcp')) {
      routes.push({
        src_node:      n.name,
        dst_subnet:    '10.0.0.0/24',
        via_transport: 'wg0-tcp',
        comment:       'fallback when UDP blocked',
      });
    }
  }

  // Stable empty string — observability metadata only, kept deterministic.
  // See cloud-data-config-derive.ts:`now` for the long-form rationale.
  const now = "";
  return {
    _meta: {
      generated_at: now,
      generated_by: '1_cloud-configs/src/derive/derive-mesh-snapshot.ts',
      schema:       'wg-mesh/v1',
      sources: {
        consolidated: consolidatedRel,
        ws_tunnel:    wsTunnelRel,
      },
    },
    nodes,
    peers,
    transports,
    routes,
    health: {
      tls_expiries:     [],          // populated by separate cert-watch deriver if/when wired
      last_snapshot_at: now,
      status:           'healthy',
    },
    bootstrap: buildBootstrap(consolidated, wsTunnel, (() => {
      try { return READ(zoneRel) as any; } catch { return null; }
    })(), { zone: zoneRel, ws_tunnel: wsTunnelRel, consolidated: consolidatedRel }),
  };
}

// ── Emit ──────────────────────────────────────────────────────────────────
function main(): void {
  const out = build();
  const outPath = path.join(DIST_DIR, 'mesh-snapshot.json');
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n');
  // eslint-disable-next-line no-console
  console.log(`[derive-mesh-snapshot] wrote ${outPath}`,
              `· ${out.nodes.length} nodes · ${out.peers.length} peers · ${out.transports.length} transports`);
}

// Only emit when run as a deriver. cloud-data-config-derive.ts imports `build()`
// to embed the same wg-mesh/v1 snapshot in the SuperApp artifact, and an
// unguarded main() would fire on that import — writing the file (and logging)
// out of turn, before this deriver's slot in derivers.json.
if (process.argv[1] && path.resolve(process.argv[1]) === import.meta.filename) {
  main();
}
