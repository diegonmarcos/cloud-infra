# 2_vault — vault-facing config

The config tier's slot for anything that describes *how this repo talks to the
vault*, as opposed to the secrets themselves.

Empty by design right now. Secrets live in the vault repo (a submodule at
`IV_vault`, or a sibling checkout — see `.claude/mcp-auth-headers.sh` for the
resolution order). Nothing decrypted and no key material belongs here: this
repo is public.

What would belong: age recipient lists that are not secret, per-repo sops
targeting rules, documentation of which vault paths this repo reads. The
`.sops.yaml` that governs encryption for this repo lives one tier over, in
`2_sops/`, because it is sops configuration rather than vault configuration.
