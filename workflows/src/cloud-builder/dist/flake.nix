{
  description = "GHA CI/CD build environment — reads deps from cloud-data-deps.json";
  # ┌──────────────────────────────────────────────────────────────────┐
  # │ ARCHITECTURE: Two-layer nix store strategy                       │
  # │                                                                  │
  # │ Layer 1 (CACHED): This devShell closure — all unix tools + node  │
  # │   Reads config.json .deps.system for nix package names.         │
  # │   shellHook installs npm packages to ~/.node_modules.            │
  # │                                                                  │
  # │ Layer 2 (EPHEMERAL): Service build outputs (docker-compose.yml)  │
  # │   GC'd after cache restore — always rebuilt fresh.               │
  # └──────────────────────────────────────────────────────────────────┘

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    # Live config.json from GitHub — always fresh, never stale
    config-json = {
      url = "https://raw.githubusercontent.com/diegonmarcos/cloud/main/config.json";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, config-json }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # Read deps from config.json fetched live from GitHub
    configJson = builtins.fromJSON (builtins.readFile config-json);
    sysDeps = configJson.deps.system;
    buildDeps = configJson.deps.build or {};
    optDeps = configJson.deps.optional;
    nodeDeps = configJson.deps.node.required or [];

    # Map config.json nix package names to actual nixpkgs attributes
    # Handles dotted paths like "nodePackages.typescript"
    resolvePkg = pkgs: nixStr:
      if nixStr == null then null
      else if builtins.match ".*\\..*" nixStr != null then
        let parts = builtins.split "\\." nixStr;
        in pkgs.${builtins.elemAt parts 0}.${builtins.elemAt parts 2}
      else pkgs.${nixStr};

    # Collect all nix packages from system + optional deps
    collectPkgs = pkgs:
      let
        sysPackages = builtins.filter (p: p != null) (
          builtins.attrValues (builtins.mapAttrs (_: v: resolvePkg pkgs (v.nix or null)) sysDeps)
        );
        buildPackages = builtins.filter (p: p != null) (
          builtins.attrValues (builtins.mapAttrs (_: v: resolvePkg pkgs (v.nix or null)) buildDeps)
        );
        optPackages = builtins.filter (p: p != null) (
          builtins.attrValues (builtins.mapAttrs (_: v: resolvePkg pkgs (v.nix or null)) optDeps)
        );
      in sysPackages ++ buildPackages ++ optPackages;

  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        buildInputs = collectPkgs pkgs;

        NODE_MODULES_DIR = "$HOME/.node_modules";

        shellHook = ''
          # ── Install npm packages to shared ~/.node_modules ──
          NM_DIR="$HOME/.node_modules"
          mkdir -p "$NM_DIR"
          export NODE_PATH="$NM_DIR/node_modules"
          export PATH="$NM_DIR/node_modules/.bin:$PATH"

          # Install required node packages (from config.json .deps.node.required)
          PKGS="${builtins.concatStringsSep " " nodeDeps}"
          if [ -n "$PKGS" ]; then
            cd "$NM_DIR"
            NEEDS_INSTALL=false
            for pkg in $PKGS; do
              [ ! -d "node_modules/$pkg" ] && NEEDS_INSTALL=true && break
            done
            if [ "$NEEDS_INSTALL" = "true" ]; then
              npm install --silent $PKGS 2>/dev/null
            fi
            cd - >/dev/null
          fi
        '';
      };
    });
  };
}
