{
  description = "Pratt certificate verifier";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
  in {
    packages = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      verifyPkg = pkgs.stdenv.mkDerivation {
        pname = "verify";
        version = "0.1.0";
        src = self;

        nativeBuildInputs = [
          pkgs.zig
          pkgs.pkg-config
        ];
        buildInputs = [pkgs.gmp];

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
    in {
      verify = verifyPkg;
      default = verifyPkg;
    });

    apps = forAllSystems (system: let
      verifyProgram = "${self.packages.${system}.verify}/bin/verify";
    in {
      verify = {
        type = "app";
        program = verifyProgram;
      };
      default = {
        type = "app";
        program = verifyProgram;
      };
    });
  };
}
