{
  description = "GHA CI/CD build environment — permanent deps layer";
  # ┌──────────────────────────────────────────────────────────────────┐
  # │ ARCHITECTURE: Two-layer nix store strategy                       │
  # │                                                                  │
  # │ Layer 1 (CACHED): This devShell closure — all build tools and    │
  # │   nixpkgs deps. Slow to fetch (~500MB), rarely changes.         │
  # │   GHA caches this between runs.                                  │
  # │                                                                  │
  # │ Layer 2 (EPHEMERAL): Service build outputs (docker-compose.yml,  │
  # │   configs). Fast to build (seconds), changes often.             │
  # │   GC'd after every cache restore — always rebuilt fresh.         │
  # │                                                                  │
  # │ Result: builds are fast (deps cached) AND correct (outputs fresh)│
  # └──────────────────────────────────────────────────────────────────┘

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        buildInputs = [
          # ── Build tools (used by nix build in service flakes) ──
          pkgs.mdbook         # Documentation generator
          pkgs.jq             # JSON processing
          pkgs.file           # MIME type detection (docs)

          # ── Secrets & deploy ──
          pkgs.sops           # Secrets decryption
          pkgs.age            # Age encryption (sops backend)
          pkgs.yq-go          # YAML processing
          pkgs.rsync          # File sync to VMs
          pkgs.openssh        # SSH for deploy + compose

          # ── Runtime (tsx for config generation) ──
          pkgs.nodejs_20      # Node.js runtime
          pkgs.nodePackages.typescript  # TypeScript

          # ── Network ──
          pkgs.wireguard-tools  # WG mesh status
          pkgs.curl             # Health checks
        ];
      };
    });
  };
}
