{
  description = "Pratt certificate verifier";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = {pkgs, ...}: let
        verifyPkg = pkgs.stdenv.mkDerivation {
          pname = "verify";
          version = "0.1.0";
          src = let
            inherit (nixpkgs.lib) fileset;
          in
            fileset.toSource {
              root = ./.;
              fileset = fileset.unions [./src];
            };

          nativeBuildInputs = with pkgs; [zig pkg-config];
          buildInputs = with pkgs; [gmp];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
            zig build-exe src/verify.zig \
              -O ReleaseSafe \
              -I ${pkgs.gmp.dev}/include \
              -L ${pkgs.gmp.out}/lib \
              -rpath ${pkgs.gmp.out}/lib \
              -lc -lgmp \
              -femit-bin=verify
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m755 verify "$out/bin/verify"
            runHook postInstall
          '';
        };
        program = pkgs.lib.getExe verifyPkg;
        verify = {
          inherit program;
          type = "app";
        };
      in {
        packages = {
          verify = verifyPkg;
          default = verifyPkg;
        };

        apps = {
          inherit verify;
          default = verify;
        };

        checks = {
          verify-small = pkgs.runCommand "verify-small" {} ''
            id=$(printf "3" | sha256sum | cut -c1-16)

            mkdir -p data
            cat > "data/$id" <<EOF
            V 1
            P 3
            W 2
            F 2
            EOF

            ${verifyPkg}/bin/verify "data/$id"
            touch "$out"
          '';
        };
      };
    };
}
