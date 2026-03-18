{
  description = "GHA CI/CD build environment — all tools declared here";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        buildInputs = [
          pkgs.sops
          pkgs.age
          pkgs.yq-go
          pkgs.rsync
          pkgs.openssh
          pkgs.wireguard-tools
        ];
      };
    });
  };
}
