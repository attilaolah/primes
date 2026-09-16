# Copyright (c) 2026
"""Prepare candidate survivors using the pre-built CUDA sieve binaries."""

import os
import pathlib
import subprocess
import sys
import time

# Ensure we run from the correct directory
os.chdir(pathlib.Path(pathlib.Path(__file__).resolve()).parent)

sys.set_int_max_str_digits(0)

DATA_DIR = "../data"


def get_largest_primes():
    """Return the three largest base primes found in the certificate data."""
    primes = []
    for f in os.listdir(DATA_DIR):
        if f == "TIP" or f.startswith("."):
            continue
        path = os.path.join(DATA_DIR, f)
        with pathlib.Path(path).open(encoding="utf-8") as cert:
            for line in cert:
                if line.startswith("P "):
                    primes.append(int(line.split()[1]))
                    break
    primes.sort(reverse=True)
    return primes[:3]


def main() -> None:
    """Run the CUDA sieve across the configured sieve limits."""
    # The `sieve` and `generate_input` binaries are expected to have been
    # built already, e.g. by `nix build .#cuda-sieve`.

    # 2. Get base primes
    primes = get_largest_primes()
    p1, p2, p3 = primes[0], primes[1], primes[2]
    base = p1 * p2 * p3 * 2

    # Convert base to 32-bit limbs (little endian)
    temp = base
    base_limbs = []
    while temp > 0:
        base_limbs.append(temp & 0xFFFFFFFF)
        temp >>= 32

    # 3. Parameters for production run
    # Let's run a massive 10 Million candidates through a 10 Billion prime limit
    N_CANDIDATES = 10000000
    Q_START = 1000000001

    sieve_sizes = [10**9, 10**10]

    for size in sieve_sizes:

        # A. Generate primes and binary input via C helper
        t0 = time.time()
        cmd = [
            "./generate_input",
            str(len(base_limbs)),
            str(N_CANDIDATES),
            str(Q_START),
            str(size),
        ] + [str(x) for x in base_limbs]
        subprocess.run(cmd, check=True)
        t1 = time.time()

        # B. Run GPU Sieve
        t0 = time.time()
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = "/run/opengl-driver/lib"
        subprocess.run(["./sieve"], check=True, env=env)
        t1 = time.time()
        t1 - t0

        # C. Read output and find survivors
        with pathlib.Path("sieve_output.bin").open("rb") as f:
            is_bad = f.read(N_CANDIDATES)

        survivors = [Q_START + 2 * k for k in range(N_CANDIDATES) if is_bad[k] == 0]

        # Save survivors
        with pathlib.Path(f"survivors_{size}.txt").open("w", encoding="utf-8") as f:
            f.writelines(f"{s}\n" for s in survivors)


if __name__ == "__main__":
    main()
