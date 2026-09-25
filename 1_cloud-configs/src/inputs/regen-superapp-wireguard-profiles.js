#!/usr/bin/env node
// Regenerate superapp-wireguard-profiles.json from cloud-vault, per peer.
//
// This is the SECRET BOUNDARY. cloud-vault is PRIVATE and holds the real
// wg-quick configs; cloud-infra is PUBLIC and this script's output is
// committed here. The PrivateKey VALUE is stripped so the public artifact can
// never carry it — the phone already holds its own key (it is the device's own
// identity) and imports it from file, so the key never needs to traverse the
// network.
//
// WHICH PEERS, WHICH FILES (#573): data, not a list here. Every peer of every
// user in superapp-users.json that declares `vault_wg_dir` is read, and every
// `config-<profile>` file in that vault directory is one profile (the bare
// `config` is the older merged profile and is not a phone profile). Adding a
// phone is a keypair dir + its mesh rows + a peer entry; this file changes not.
//
// The PresharedKey guard is deliberate: as of 2026-08-31 none of the configs
// has one, so PrivateKey is the only secret line. If a PresharedKey is ever
// added upstream this script REFUSES rather than silently publishing it.
//
// Usage: node 1_cloud-configs/src/inputs/regen-superapp-wireguard-profiles.js
//        WG_VAULT_DIR overrides the vault's wireguard providers directory.
const { readFileSync, writeFileSync, readdirSync } = require("fs");
const { join } = require("path");

const VAULT =
  process.env.WG_VAULT_DIR ?? join(process.env.HOME, "git/cloud-vault/A0_keys/providers/wireguard");
const PLACEHOLDER = "<PROVIDED_BY_DEVICE>";
const users = JSON.parse(readFileSync(join(__dirname, "superapp-users.json"), "utf-8")).users;

const out = {
  _doc:
    "Redacted wg-quick profiles for the Cloud SuperApp full-config artifact, ONE MAP PER PEER (profiles.<peer id>.<profile id>). SECURITY: the PrivateKey VALUE is stripped at the source boundary, so this PUBLIC repo can never carry it. Real keys stay in cloud-vault (PRIVATE); the device holds its own key and imports it from file.",
  _source:
    "cloud-vault/A0_keys/providers/wireguard/<peer.vault_wg_dir>/config-* for every peer in superapp-users.json that declares vault_wg_dir",
  _regenerate: "node 1_cloud-configs/src/inputs/regen-superapp-wireguard-profiles.js",
  private_key_placeholder: PLACEHOLDER,
  profiles: {},
};

let n = 0;
for (const user of Object.values(users)) {
  for (const [peerId, peer] of Object.entries(user.peers ?? {})) {
    if (!peer.vault_wg_dir) continue;
    const dir = join(VAULT, peer.vault_wg_dir);
    const files = readdirSync(dir).filter((f) => f.startsWith("config-")).sort();
    if (files.length === 0) throw new Error(`${peerId}: no config-* file under ${dir}`);
    out.profiles[peerId] = {};
    for (const file of files) {
      const p = file.slice("config-".length);
      const raw = readFileSync(join(dir, file), "utf-8");
      if (/PresharedKey/.test(raw)) {
        throw new Error(`PresharedKey found in ${peerId}/${file} — redaction list is incomplete, refusing`);
      }
      const text = raw.replace(/^(\s*PrivateKey\s*=\s*).*$/gm, `$1${PLACEHOLDER}`);
      if (new RegExp(`PrivateKey\\s*=\\s*(?!${PLACEHOLDER})\\S`).test(text)) {
        throw new Error(`redaction failed for ${peerId}/${file}`);
      }
      out.profiles[peerId][p] = { name: `wg-${p}`, config_text: text };
      n++;
    }
  }
}
if (n === 0) throw new Error("no peer declares vault_wg_dir — nothing to publish");

writeFileSync(join(__dirname, "superapp-wireguard-profiles.json"), JSON.stringify(out, null, 2) + "\n");
console.log(`wrote ${n} redacted profiles for ${Object.keys(out.profiles).length} peer(s)`);
