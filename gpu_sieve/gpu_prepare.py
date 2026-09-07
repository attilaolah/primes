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

def main():
    print("[*] GPU Sieve Profiler Starting...")
    
    print("[*] Compiling C Input Generator...")
    subprocess.run(["nix-shell", "-p", "gcc", "--run", "gcc -O3 generate_input.c -o generate_input"], check=True)
    
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
    
    # 3. Parameters for production run
    # Let's run a massive 10 Million candidates through a 10 Billion prime limit
    N_CANDIDATES = 10000000
    Q_START = 1000000001
    
    sieve_sizes = [10**9, 10**10]
    
    for size in sieve_sizes:
        print(f"\n======================================")
        print(f"[*] Executing Sieve Limit: {size:,}")
        
        # A. Generate primes and binary input via C helper
        t0 = time.time()
        cmd = ["./generate_input", str(len(base_limbs)), str(N_CANDIDATES), str(Q_START), str(size)] + [str(x) for x in base_limbs]
        subprocess.run(cmd, check=True)
        t1 = time.time()
        print(f"  -> Generated primes and wrote payload in {t1-t0:.2f}s")
        
        # B. Run GPU Sieve
        t0 = time.time()
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = "/run/opengl-driver/lib"
        subprocess.run(["./sieve"], check=True, env=env)
        t1 = time.time()
        gpu_time = t1 - t0
        print(f"  -> [GPU KERNEL] Sieve execution took: {gpu_time:.4f}s")
        
        # C. Read output and find survivors
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
                
    print("\n[*] GPU Sieve complete! Candidates saved to text files ready for scp.")

if __name__ == "__main__":
    main()
