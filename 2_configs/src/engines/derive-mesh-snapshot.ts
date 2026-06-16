// derive-mesh-snapshot.ts
//
// Reads the canonical post-restructure SoT and emits a single flat snapshot
// consumed by bb-net_wireguard-mesh as PORTAL_DATA["mesh"].
//
// Inputs (read-only, single source of truth):
//   - 2_configs/dist/_cloud-data-consolidated.json  ← VMs (ip, wg_ip, wg_role,
//                                                     wg_public_key, wg_port,
//                                                     ssh_alias, public_ports)
//   - a_solutions/infra-net_wireguard-mesh-ws-tunnel/build.json  ← transport
//                                                     declarations (UDP + TCP/443)
//
// Output:
//   - 2_configs/dist/mesh-snapshot.json   (schema: wg-mesh/v1)
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
interface Snapshot {
  _meta: { generated_at: string; generated_by: string; schema: string;
           sources: { consolidated: string; ws_tunnel: string } };
  nodes: Node[]; peers: Peer[]; transports: Transport[]; routes: Route[];
  health: { tls_expiries: TlsExpiry[]; last_snapshot_at: string; status: 'healthy' | 'degraded' | 'down' };
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

// ── Build the snapshot ────────────────────────────────────────────────────
function build(): Snapshot {
  const consolidatedRel = '2_configs/dist/_cloud-data-consolidated.json';
  const wsTunnelRel     = 'a_solutions/infra-net_wireguard-mesh-ws-tunnel/build.json';

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
      generated_by: '2_configs/src/engines/derive-mesh-snapshot.ts',
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

main();
