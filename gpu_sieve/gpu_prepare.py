import os
import sys
import time
import struct
import subprocess

# Ensure we run from the correct directory
os.chdir(os.path.dirname(os.path.abspath(__file__)))

sys.set_int_max_str_digits(0)

DATA_DIR = "../data"

def get_largest_primes():
    primes = []
    for f in os.listdir(DATA_DIR):
        if f == "TIP" or f.startswith("."): continue
        path = os.path.join(DATA_DIR, f)
        with open(path) as cert:
            for line in cert:
                if line.startswith("P "):
                    primes.append(int(line.split()[1]))
                    break
    primes.sort(reverse=True)
    return primes[:3]

def get_primes(limit):
    """Fast pure-python bytearray sieve to get primes up to `limit`."""
    sieve = bytearray([1]) * (limit // 2)
    for i in range(3, int(limit**0.5) + 1, 2):
        if sieve[i//2]:
            sieve[i*i//2::i] = bytearray([0]) * len(sieve[i*i//2::i])
    return [2] + [2*i+1 for i, v in enumerate(sieve) if v and i > 0]

def main():
    print("[*] GPU Sieve Profiler Starting...")
    
    # 1. Compile the CUDA kernel
    print("[*] Compiling CUDA Sieve Kernel...")
    subprocess.run(["env", "NIXPKGS_ALLOW_UNFREE=1", "nix-shell", "-p", "cudatoolkit", "--run", "nvcc -O3 -arch=native sieve.cu -o sieve"], check=True)
    
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
        
    print(f"[*] Base is {len(base_limbs)} limbs (32-bit).")
    
    # 3. Parameters for profiling
    # We will test N=10,000,000 candidates starting from an arbitrary offset
    N_CANDIDATES = 10000000
    Q_START = 1000000001
    
    sieve_sizes = [10**6, 10**7, 10**8]
    
    for size in sieve_sizes:
        print(f"\n======================================")
        print(f"[*] Profiling Sieve Limit: {size:,}")
        
        # A. Generate primes
        t0 = time.time()
        sieve_primes = get_primes(size)
        t1 = time.time()
        print(f"  -> Generated {len(sieve_primes):,} primes in {t1-t0:.2f}s")
        
        # B. Write input binary
        t0 = time.time()
        with open("sieve_input.bin", "wb") as f:
            f.write(struct.pack("<I", len(base_limbs)))
            f.write(struct.pack("<I", len(sieve_primes)))
            f.write(struct.pack("<I", N_CANDIDATES))
            f.write(struct.pack("<Q", Q_START))
            for limb in base_limbs:
                f.write(struct.pack("<I", limb))
            for p in sieve_primes:
                f.write(struct.pack("<Q", p))
        t1 = time.time()
        print(f"  -> Wrote binary payload in {t1-t0:.2f}s")
        
        # C. Run GPU Sieve
        t0 = time.time()
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = "/run/opengl-driver/lib"
        subprocess.run(["./sieve"], check=True, env=env)
        t1 = time.time()
        gpu_time = t1 - t0
        print(f"  -> [GPU KERNEL] Sieve execution took: {gpu_time:.4f}s")
        
        # D. Read output and find survivors
        with open("sieve_output.bin", "rb") as f:
            is_bad = f.read(N_CANDIDATES)
            
        survivors = []
        for k in range(N_CANDIDATES):
            if is_bad[k] == 0:
                survivors.append(Q_START + 2 * k)
                
        print(f"  -> Out of {N_CANDIDATES:,} candidates, {len(survivors):,} survived the {size:,} sieve.")
        
        # Save survivors
        with open(f"survivors_{size}.txt", "w") as f:
            for s in survivors:
                f.write(f"{s}\n")
                
    print("\n[*] Profiling complete! Candidates saved to text files.")

if __name__ == "__main__":
    main()
