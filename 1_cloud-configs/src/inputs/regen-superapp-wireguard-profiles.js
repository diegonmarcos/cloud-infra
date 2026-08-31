#!/usr/bin/env node
// Regenerate superapp-wireguard-profiles.json from cloud-vault.
//
// This is the SECRET BOUNDARY. cloud-vault is PRIVATE and holds the real
// wg-quick configs; cloud-infra is PUBLIC and this script's output is
// committed here. The PrivateKey VALUE is stripped so the public artifact can
// never carry it — the phone already holds its own key (it is the device's own
// identity) and imports it from file, so the key never needs to traverse the
// network.
//
// The PresharedKey guard is deliberate: as of 2026-08-31 none of the four
// configs has one, so PrivateKey is the only secret line. If a PresharedKey is
// ever added upstream this script REFUSES rather than silently publishing it.
//
// Usage: node 1_cloud-configs/src/inputs/regen-superapp-wireguard-profiles.js
const { readFileSync, writeFileSync } = require("fs");
const { join } = require("path");

const SRC =
  process.env.WG_TERMUX_PUBLIC_DIR ??
  join(process.env.HOME, "git/cloud-vault/A0_keys/providers/wireguard/termux-public");
const PLACEHOLDER = "<PROVIDED_BY_DEVICE>";
const PROFILES = ["v4-full", "v4-split", "v6-full", "v6-split"];

const out = {
  _doc:
    "Redacted wg-quick profiles for the Cloud SuperApp full-config artifact. SECURITY: the PrivateKey VALUE is stripped at the source boundary, so this PUBLIC repo can never carry it. Real keys stay in cloud-vault (PRIVATE); the device holds its own key and imports it from file.",
  _source:
    "cloud-vault/A0_keys/providers/wireguard/termux-public/config-{v4-full,v4-split,v6-full,v6-split}",
  _regenerate: "node 1_cloud-configs/src/inputs/regen-superapp-wireguard-profiles.js",
  private_key_placeholder: PLACEHOLDER,
  profiles: {},
};

for (const p of PROFILES) {
  const raw = readFileSync(join(SRC, `config-${p}`), "utf-8");
  if (/PresharedKey/.test(raw)) {
    throw new Error(`PresharedKey found in config-${p} — redaction list is incomplete, refusing`);
  }
  const text = raw.replace(/^(\s*PrivateKey\s*=\s*).*$/gm, `$1${PLACEHOLDER}`);
  if (new RegExp(`PrivateKey\\s*=\\s*(?!${PLACEHOLDER})\\S`).test(text)) {
    throw new Error(`redaction failed for config-${p}`);
  }
  out.profiles[p] = { name: `wg-${p}`, config_text: text };
}

writeFileSync(join(__dirname, "superapp-wireguard-profiles.json"), JSON.stringify(out, null, 2) + "\n");
console.log(`wrote ${PROFILES.length} redacted profiles`);
