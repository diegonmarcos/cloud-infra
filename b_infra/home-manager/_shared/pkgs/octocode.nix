{ lib, stdenv, fetchurl, autoPatchelfHook }:

let
  version = "0.12.2";
  assets = {
    x86_64-linux = {
      url = "https://github.com/Muvon/octocode/releases/download/${version}/octocode-${version}-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256:0iwcyig9kkplmd008mc274dhvfsqfm0gpdf7q95zf0m84pvjba4s";
    };
    aarch64-linux = {
      url = "https://github.com/Muvon/octocode/releases/download/${version}/octocode-${version}-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256:1qkk96xqbsi1jzgrlkgyzsqnzyvfz1nc132cj87ppm1fskylaagg";
    };
  };
  asset = assets.${stdenv.hostPlatform.system} or (throw "octocode: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "octocode";
  inherit version;

  src = fetchurl {
    inherit (asset) url hash;
  };

  sourceRoot = ".";
  unpackPhase = "tar xf $src";

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  installPhase = ''
    mkdir -p $out/bin
    cp octocode $out/bin/
    chmod +x $out/bin/octocode
  '';

  meta = with lib; {
    description = "Semantic code search and indexing tool";
    homepage = "https://github.com/Muvon/octocode";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
