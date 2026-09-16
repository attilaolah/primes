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
        cudaSievePython = pkgs.python3.withPackages (ps: [ps.rich]);
        cudaSieve = pkgs.stdenv.mkDerivation {
          pname = "cuda-sieve";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./cuda_sieve/sieve.cu
              ./cuda_sieve/generate_input.c
              ./cuda_sieve/cuda_sieve_runner.py
            ];
          };
          nativeBuildInputs = [pkgs.cudaPackages.cuda_nvcc pkgs.makeWrapper];
          buildInputs = [pkgs.cudaPackages.cudatoolkit];
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            mkdir -p "$out/bin"
            nvcc -O3 -arch=native cuda_sieve/sieve.cu -o "$out/bin/sieve"
            gcc -O3 cuda_sieve/generate_input.c -o "$out/bin/generate_input"
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -m755 cuda_sieve/cuda_sieve_runner.py "$out/bin/cuda-sieve-runner"
            wrapProgram "$out/bin/cuda-sieve-runner" \
              --prefix PATH : "$out/bin" \
              --prefix PATH : ${cudaSievePython}/bin
            runHook postInstall
          '';
          meta = {
            description = "CUDA-backed infinite candidate pre-sieve.";
            mainProgram = "cuda-sieve-runner";
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
          cuda-sieve = cudaSieve;
          default = verifyPkg;
        };

        apps = {
          inherit verify;
          cuda-sieve = {
            program = "${cudaSieve}/bin/cuda-sieve-runner";
            type = "app";
          };
          default = verify;
        };

        devShells.default = pkgs.mkShell {
          packages = [pkgs.ruff];
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
