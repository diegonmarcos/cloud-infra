# Static list of known npm dependencies — always installed.
# This is the declarative source of truth for essential tools.
# Cloud and front deps are merged on top by their respective modules.
{ lib, ... }:

{
  # Nix option: list of { name, version } attrs
  options.nodeNpmDeps.static = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Static npm dependencies to always install";
  };

  config.nodeNpmDeps.static = {
    # ── Essential CLI tools ──
    "tsx" = "^4.19.0";
    "typescript" = "^5.7.0";

    # ── MCP SDK ──
    "@modelcontextprotocol/sdk" = "^1.12.0";

    # ── Server frameworks (cloud services) ──
    "fastify" = "^5.2.0";
    "fastify-plugin" = "^5.0.0";
    "@fastify/cors" = "^10.0.0";
    "@fastify/static" = "^8.0.0";
    "@fastify/swagger" = "^9.4.0";
    "@fastify/swagger-ui" = "^5.2.0";

    # ── Schema / validation ──
    "zod" = "^3.25.0";
    "zod-to-json-schema" = "^3.24.0";

    # ── Templating ──
    "nunjucks" = "^3.2.4";
    "yaml" = "^2.6.0";

    # ── Database ──
    "better-sqlite3" = "^11.0.0";

    # ── Mail ──
    "imapflow" = "^1.0.0";
    "mailparser" = "^3.7.0";
    "nodemailer" = "^6.9.0";

    # ── Types ──
    "@types/node" = "^22.0.0";
    "@types/better-sqlite3" = "^7.6.13";
    "@types/nunjucks" = "^3.2.6";
    "@types/nodemailer" = "^6.4.0";
  };
}
