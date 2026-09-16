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
      perSystem = {system, ...}: let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
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

          meta = {
            description = "Pratt certificate verifier.";
            maintainers = with pkgs.lib.maintainers; [attila];
            mainProgram = "verify";
          };
        };
        candidateFilter = pkgs.stdenv.mkDerivation {
          pname = "candidate-filter";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [pkgs.pkg-config];
          buildInputs = [pkgs.gmp pkgs.stdenv.cc.cc.lib];
          dontConfigure = true;
          buildPhase = ''
            $CC -std=c11 -O3 -fPIC -shared -fopenmp "$src/candidate_filter.c" \
              -I ${pkgs.gmp.dev}/include \
              -L ${pkgs.gmp.out}/lib -Wl,-rpath,${pkgs.gmp.out}/lib \
              -Wl,-rpath,${pkgs.stdenv.cc.cc.lib}/lib -lgmp \
              -o libcandidate_filter${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
          '';
          installPhase = ''
            mkdir -p "$out/lib"
            install -m755 libcandidate_filter${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/"
          '';
        };
        gpuSievePython = pkgs.python3.withPackages (ps: [ps.rich]);
        gpuSieve = pkgs.stdenv.mkDerivation {
          pname = "gpu-sieve";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./gpu_sieve/sieve.cu
              ./gpu_sieve/generate_input.c
              ./gpu_sieve/sieve_runner.py
            ];
          };
          nativeBuildInputs = [pkgs.cudaPackages.cuda_nvcc pkgs.makeWrapper];
          buildInputs = [pkgs.cudaPackages.cudatoolkit];
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            mkdir -p "$out/bin"
            nvcc -O3 -arch=native gpu_sieve/sieve.cu -o "$out/bin/sieve"
            gcc -O3 gpu_sieve/generate_input.c -o "$out/bin/generate_input"
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -m755 gpu_sieve/sieve_runner.py "$out/bin/sieve-runner"
            wrapProgram "$out/bin/sieve-runner" \
              --prefix PATH : "$out/bin" \
              --prefix PATH : ${gpuSievePython}/bin
            runHook postInstall
          '';
          meta = {
            description = "GPU-backed infinite candidate pre-sieve.";
            mainProgram = "sieve-runner";
          };
        };
        program = pkgs.lib.getExe verifyPkg;
        verify = {
          inherit program;
          type = "app";
        };
      in {
        packages = {
          verify = verifyPkg;
          candidate-filter = candidateFilter;
          gpu-sieve = gpuSieve;
          default = verifyPkg;
        };

        apps = {
          inherit verify;
          gpu-sieve = {
            program = "${gpuSieve}/bin/sieve-runner";
            type = "app";
          };
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
