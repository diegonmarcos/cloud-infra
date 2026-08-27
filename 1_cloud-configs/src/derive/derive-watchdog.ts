// derive-watchdog.ts
//
// Reads the consolidated SoT and emits the one lean file my-watchdog's
// dashboard needs, so the panel is driven by the cloud declaration rather
// than by anything hardcoded in Rust.
//
// Input (read-only, single source of truth):
//   - 1_cloud-configs/dist/_cloud-data-consolidated.json
//
// Output:
//   - 1_cloud-configs/dist/watchdog.json   (schema: watchdog/v1)
//
// NOT build-watchdog.json: dist/build-*.json is the per-solution namespace,
// symlinked from a_solutions/<folder>/build.json and pruned by build.sh when
// no producer exists. A derived artifact with no solution behind it uses a
// bare name, the way mesh-snapshot.json and cloud-fleet-declared.json do.
//
// Per fire-rule 6: no hardcoded node lists, IPs or endpoints. Adding a VM to
// the consolidated data makes it appear in the panel on the next deploy.

import * as fs from 'node:fs';
import * as path from 'node:path';

const ENGINE_DIR  = import.meta.dirname!;
const CONFIGS_DIR = path.resolve(ENGINE_DIR, '..', '..');
const DIST_DIR    = path.join(CONFIGS_DIR, 'dist');
const SRC         = path.join(DIST_DIR, '_cloud-data-consolidated.json');
const OUT         = path.join(DIST_DIR, 'watchdog.json');

const j = JSON.parse(fs.readFileSync(SRC, 'utf8')) as Record<string, any>;

// ── provider ──────────────────────────────────────────────────────────────
// From the shape, which is the only provider-specific string every VM
// carries. An explicit `provider` on the VM wins when it is there.
//
// An UNKNOWN provider is not an error and not a guess: that machine simply
// gets no console actions and stays ssh-only. Silently emitting the wrong
// CLI would be worse than emitting none — one of these commands stops a
// production VM.
function providerOf(vm: any): string {
  if (typeof vm.provider === 'string') return vm.provider;
  const shape = String(vm?.specs?.shape ?? '');
  if (/^VM\.Standard/i.test(shape)) return 'oci';
  if (/^(e2|n1|n2|c2|t2a)-/i.test(shape)) return 'gcp';
  return 'unknown';
}

// ── the two transports, as DATA ───────────────────────────────────────────
// The commands live here rather than in the dashboard so the panel never has
// to know oci(1) from gcloud(1). It runs the string for whichever transport
// is toggled, and a provider it has no commands for offers no buttons.
//
// ssh can reboot and shut down; it can NEVER start, because starting is what
// you need precisely when nothing is listening. That asymmetry is in the data
// rather than left for the UI to discover.
function actions(name: string, vm: any) {
  const p = providerOf(vm);
  const alias = vm.ssh_alias ?? name;
  const id = vm?.specs?.instance_id;
  const zone = vm?.specs?.cloud_zone;

  const ssh: Record<string, string> = {
    stop:    `ssh ${alias} sudo systemctl poweroff`,
    restart: `ssh ${alias} sudo systemctl reboot`,
  };

  const console_: Record<string, string> = {};
  if (p === 'oci' && id) {
    for (const [verb, action] of [['start','START'],['stop','STOP'],['restart','SOFTRESET'],['reset','RESET']]) {
      console_[verb] = `oci compute instance action --action ${action} --instance-id ${id}`;
    }
  } else if (p === 'gcp' && id && zone) {
    console_.start   = `gcloud compute instances start ${id} --zone ${zone}`;
    console_.stop    = `gcloud compute instances stop ${id} --zone ${zone}`;
    console_.restart = `gcloud compute instances reset ${id} --zone ${zone}`;
    console_.reset   = console_.restart;
  }
  return { ssh, console: console_ };
}

// ── declared containers, per machine ──────────────────────────────────────
// What SHOULD be running there, so the panel can show declared-against-actual.
//
// Only the categories that are containers. db-embedded, db-s3, db-hd, the
// volume categories and the git ones are declarations of other things
// entirely, and counting them would make every machine look under-deployed.
//
// The service id is the stable identity; `container` is compose's local role
// name ("app", "db"), which is not unique across stacks and must never be the
// thing a drift check keys on.
const CTR_CATEGORIES = ['runners', 'apis', 'mcps', 'db-dockers'];
function declaredFor(vm: string, cats: Record<string, any[]>): string[] {
  const out = new Set<string>();
  for (const k of CTR_CATEGORIES) {
    for (const e of cats[k] ?? []) {
      if (e?.vm !== vm) continue;
      const id = e.service ?? e.name ?? e.id;
      if (id) out.add(String(id).split('/')[0]);
    }
  }
  return [...out].sort();
}

// The declared-container lists live in a sibling derived file rather than in
// consolidated directly; read it when present so this deriver does not have
// to re-implement the categorisation that one already does.
const DECLARED = path.join(DIST_DIR, 'cloud-fleet-containers-declared.json');
const cats: Record<string, any[]> = fs.existsSync(DECLARED)
  ? (JSON.parse(fs.readFileSync(DECLARED, 'utf8')).categories ?? {})
  : {};

const machines = Object.entries(j.vms ?? {}).map(([name, vm]: [string, any]) => ({
  name,
  provider: providerOf(vm),
  alias: vm.ssh_alias ?? name,
  ip: vm.ip,
  wg_ip: vm.wg_ip ?? null,
  wg_role: vm.wg_role ?? null,
  user: vm.user ?? null,
  arch: vm?.specs?.arch ?? null,
  cpu: vm?.specs?.cpu ?? null,
  ram_gb: vm?.specs?.ram_gb ?? null,
  shape: vm?.specs?.shape ?? null,
  zone: vm?.specs?.cloud_zone ?? null,
  instance_id: vm?.specs?.instance_id ?? null,
  rescue_port: vm.rescue_port ?? null,
  public_ports: vm.public_ports ?? [],
  description: vm.description ?? '',
  declared: declaredFor(name, cats),
  actions: actions(name, vm),
}));

// ── firewall ──────────────────────────────────────────────────────────────
// Shipped whole: `os` is the per-host declared ingress, `global` the
// forward/NAT policy, `terraform` what the cloud provider is told. The panel
// shows declared-vs-actual, so it needs the declaration verbatim.
const fw = j.firewalls ?? {};
const out = {
  _warning: 'DO NOT EDIT — AUTO-GENERATED by 1_cloud-configs/src/derive/derive-watchdog.ts',
  _meta: {
    schema: 'watchdog/v1',
    generated_from: 'dist/_cloud-data-consolidated.json',
    machines: machines.length,
    firewall_hosts: Object.keys(fw.os ?? {}).length,
  },
  machines,
  firewall: { global: fw.global ?? {}, hosts: fw.os ?? {}, terraform: fw.terraform ?? {} },
  storage: j.storage ?? [],
  wireguard_public: j.wireguard_public ?? {},
};

fs.writeFileSync(OUT, JSON.stringify(out, null, 2) + '\n');
const noConsole = machines.filter((m) => !Object.keys(m.actions.console).length).map((m) => m.name);
const dec = machines.reduce((n, m) => n + m.declared.length, 0);
console.log(`[derive-watchdog] ${machines.length} machines, ${dec} declared containers, ${Object.keys(out.firewall.hosts).length} firewall hosts → dist/watchdog.json`);
if (noConsole.length) console.log(`[derive-watchdog] ssh-only (no console actions): ${noConsole.join(', ')}`);
