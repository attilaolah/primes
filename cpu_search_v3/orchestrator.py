import argparse
import os
import sys
import subprocess
import hashlib
import time

# Ensure we are always running from the script's directory for relative paths
os.chdir(os.path.dirname(os.path.abspath(__file__)))

sys.set_int_max_str_digits(0)

DATA_DIR = "../data"
TIP_FILE = "../TIP"

def get_cert_hash(prime_str):
    return hashlib.sha256(prime_str.encode('ascii')).hexdigest()[:16]

def save_cert(prime_str, content):
    h = get_cert_hash(prime_str)
    path = os.path.join(DATA_DIR, h)
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(content)
    return h

def get_factors(n):
    factors = []
    d = 2
    while d * d <= n:
        if n % d == 0:
            factors.append(d)
            while n % d == 0:
                n //= d
        d += 1
    if n > 1:
        factors.append(n)
    return factors

def find_witness(p, factors):
    for w in range(2, p):
        if pow(w, p-1, p) != 1: continue
        valid = True
        for f in factors:
            if pow(w, (p-1)//f, p) == 1:
                valid = False
                break
        if valid: return w
    return None

def certify_prime(p):
    """Recursively generates Pratt certificates for a prime and all its prime factors."""
    if p == 2:
        return save_cert("2", "V 1\nP 2\n")
        
    factors = get_factors(p - 1)
    for f in factors:
        certify_prime(f)
        
    w = find_witness(p, factors)
    
    temp = p - 1
    grouped = {}
    for f in factors:
        count = 0
        while temp % f == 0:
            count += 1
            temp //= f
        grouped[f] = count
        
    lines = [f"V 1", f"P {p}", f"W {w}"]
    for f in sorted(grouped.keys()):
        if grouped[f] == 1:
            lines.append(f"F {f}")
        else:
            lines.append(f"F {f}^{grouped[f]}")
            
    return save_cert(str(p), "\n".join(lines) + "\n")

def get_largest_primes(max_digits=None):
    primes = []
    for f in os.listdir(DATA_DIR):
        if f == "TIP" or f.startswith("."): continue
        path = os.path.join(DATA_DIR, f)
        with open(path) as cert:
            for line in cert:
                if line.startswith("P "):
                    prime_str = line.split()[1]
                    if max_digits is None or len(prime_str) <= max_digits:
                        primes.append(int(prime_str))
                    break
    primes.sort(reverse=True)
    return primes[:3]

import math

def calculate_optimal_sieve_limit():
    # Deep Sieve Mode (Override L2 Cache constraints)
    # At this scale (10+ min Fermat tests), we want to filter candidates as aggressively as possible.
    # 5 Billion takes ~5GB of RAM and ~2 minutes to init, but completely eliminates false positives
    # caused by factors up to 5,000,000,000.
    print("[*] Deep Sieve Enabled: Bypassing cache boundaries for max filtration.")
    return 5000000000

def run_search(max_digits=None, sieve_limit=None):
    print("[*] V3 Dynamic Fermat Search Orchestrator Started")
    print("[*] Compiling C core (v3)...")
    import platform
    if platform.system() == "Darwin":
        # Apple Silicon native optimizations (M-series specific tuning), bypassing Nix impurity checks
        subprocess.run(["nix-shell", "-p", "gcc", "gmp", "--run", "env NIX_ENFORCE_NO_NATIVE=0 gcc -O3 -mcpu=native -mtune=native -fopenmp worker.c -lm -lgmp -o worker"], check=True)
    else:
        subprocess.run(["nix-shell", "-p", "gcc", "gmp", "--run", "gcc -O3 -fopenmp worker.c -lm -lgmp -o worker"], check=True)
    
    max_sieve = sieve_limit if sieve_limit is not None else calculate_optimal_sieve_limit()
    
    while True:
        print("\n[*] Scanning data/ for the 3 largest primes...")
        primes = get_largest_primes(max_digits)
        if len(primes) < 3:
            print("[-] Not enough large primes in data/")
            return
        
        p1, p2, p3 = primes[0], primes[1], primes[2]
        print(f"[+] Found Base Primes: {len(str(p1))} digits, {len(str(p2))} digits, {len(str(p3))} digits")
        
        with open("search_input.txt", "w") as f:
            f.write(f"{p1}\n{p2}\n{p3}\n{max_sieve}\n")
            
        print("[+] Launching C core...")
        process = subprocess.Popen(["./worker"], stdout=subprocess.PIPE)
        assert process.stdout is not None
        
        cert_lines = []
        capturing = False
        
        line_buffer = bytearray()
        while True:
            character = process.stdout.read(1)
            if character == b"":
                break
            sys.stdout.buffer.write(character)
            sys.stdout.flush()

            if character != b"\n":
                line_buffer.extend(character)
                continue

            line = line_buffer.decode("ascii")
            line_buffer.clear()
            if "*** Found valid prime!" in line:
                capturing = True
                cert_lines = []
                continue
                
            if capturing:
                if line.strip() == "":
                    continue
                cert_lines.append(line.strip())

        process.wait()
        
        if capturing and len(cert_lines) > 4:
            new_p = 0
            w = 0
            factors = []
            for line in cert_lines:
                if line.startswith("P "): new_p = int(line.split()[1])
                elif line.startswith("W "): w = int(line.split()[1])
                elif line.startswith("F "): factors.append(int(line.split()[1]))
            
            print(f"\n[+] SUCCESS! Acquired new massive prime of {len(str(new_p))} digits!")
            
            # The new small prime 'q' is the factor that is not 2 and not P1, P2, P3
            q = [f for f in factors if f != 2 and f != p1 and f != p2 and f != p3][0]
            print(f"[+] Retroactively certifying small prime factor q = {q}...")
            certify_prime(q)
            
            # Format the final certificate nicely
            lines = [f"V 1", f"P {new_p}", f"W {w}"]
            
            temp = new_p - 1
            grouped = {}
            for f in factors:
                count = 0
                while temp % f == 0:
                    count += 1
                    temp //= f
                grouped[f] = count
                
            for f in sorted(grouped.keys()):
                if grouped[f] == 1:
                    lines.append(f"F {f}")
                else:
                    lines.append(f"F {f}^{grouped[f]}")
                    
            final_cert = "\n".join(lines) + "\n"
            h = save_cert(str(new_p), final_cert)
            
            print(f"[+] Saved new 20,000+ digit prime certificate: {h}")
            with open(TIP_FILE, "w") as f:
                f.write(h + "\n")
            print("[+] Updated TIP! Restarting pipeline for the next generation...\n")
            time.sleep(2)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--max-digits",
        type=int,
        help="select only primes with at most this many decimal digits",
    )
    parser.add_argument(
        "--sieve-limit",
        type=int,
        help="set the sieve limit used by the worker",
    )
    args = parser.parse_args()
    if args.max_digits is not None and args.max_digits <= 0:
        parser.error("--max-digits must be a positive integer")
    if args.sieve_limit is not None and args.sieve_limit <= 0:
        parser.error("--sieve-limit must be a positive integer")
    run_search(args.max_digits, args.sieve_limit)
