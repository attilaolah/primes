import os
import sys
import subprocess
import time

sys.set_int_max_str_digits(0)

# Ensure we run from the script's directory
os.chdir(os.path.dirname(os.path.abspath(__file__)))

DATA_DIR = "../data"
BATCH_SIZE = 10  # Feed 10 candidates to the worker at a time

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
    if len(sys.argv) < 2:
        print(f"Usage: python3 {sys.argv[0]} <path_to_survivors.txt>")
        sys.exit(1)
        
    survivors_file = sys.argv[1]
    if not os.path.exists(survivors_file):
        print(f"[-] File not found: {survivors_file}")
        sys.exit(1)
        
    print("[*] Compiling CPU Fermat Worker...")
    subprocess.run(["env", "NIX_ENFORCE_NO_NATIVE=0", "nix-shell", "-p", "gcc", "gmp", "--run", "gcc -O3 -fopenmp fermat_worker.c -lgmp -o fermat_worker"], check=True)

    print("[*] Loading base primes...")
    primes = get_largest_primes()
    p1, p2, p3 = primes[0], primes[1], primes[2]

    # Load all survivors
    with open(survivors_file, "r") as f:
        all_qs = [int(line.strip()) for line in f if line.strip()]
        
    print(f"[*] Found {len(all_qs)} total survivors in {survivors_file}.")
    
    # Load previously tested Qs to avoid duplicate work
    tested_file = "tested.txt"
    tested = set()
    if os.path.exists(tested_file):
        with open(tested_file, "r") as f:
            for line in f:
                if line.strip():
                    tested.add(int(line.strip()))
                    
    # Filter out the tested ones
    remaining_qs = [q for q in all_qs if q not in tested]
    print(f"[*] {len(tested)} already tested. {len(remaining_qs)} remaining to test.")
    
    if not remaining_qs:
        print("[*] All candidates in this file have been tested. Exiting.")
        sys.exit(0)

    # Process in batches
    for i in range(0, len(remaining_qs), BATCH_SIZE):
        batch = remaining_qs[i:i + BATCH_SIZE]
        
        # Write batch input
        with open("batch_input.txt", "w") as f:
            f.write(f"{p1}\n{p2}\n{p3}\n")
            f.write(f"{len(batch)}\n")
            for q in batch:
                f.write(f"{q}\n")
                
        # Run worker
        result = subprocess.run(["./fermat_worker"])
        
        if result.returncode == 0:
            print("\n[!!!] WORKER EXITED WITH SUCCESS. PRIME FOUND!")
            sys.exit(0)
        elif result.returncode == 2:
            # Not found, append to tested
            with open(tested_file, "a") as f:
                for q in batch:
                    f.write(f"{q}\n")
        else:
            print(f"[-] Worker crashed with return code {result.returncode}")
            sys.exit(result.returncode)

    print("\n[*] Exhausted all candidates in the survivor file.")

if __name__ == "__main__":
    main()
