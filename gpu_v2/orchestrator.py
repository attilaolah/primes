import os
import sys
import struct
import math
import subprocess

sys.set_int_max_str_digits(0)

DATA_DIR = "data"
BATCH_SIZE = 128
L_DIGITS = 31945
N_SIZE = 65536

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

def encode_base128(num, size):
    arr = []
    for _ in range(size):
        arr.append(num & 127)
        num >>= 7
    return arr

def main():
    print("[*] GPU V2 Orchestrator Starting...")
    primes = get_largest_primes()
    if len(primes) < 3:
        print("[-] Not enough base primes.")
        return
        
    p1, p2, p3 = primes[0], primes[1], primes[2]
    base = p1 * p2 * p3 * 2
    
    print(f"[*] Base calculated. Size: {len(str(base))} digits")
    
    # 1. Simple Sieve for 128 candidates
    print("[*] Sieving 128 candidates...")
    candidates = []
    q = 3
    while len(candidates) < BATCH_SIZE:
        if all(q % p != 0 for p in [2,3,5,7,11,13,17,19,23,29,31]):
            # Quick divisibility test for P
            is_valid = True
            P = base * q + 1
            for small_p in [3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97]:
                if P % small_p == 0:
                    is_valid = False
                    break
            if is_valid:
                candidates.append((q, P))
        q += 2
        
    print(f"[+] Sieve complete. Formulating Barrett bounds for GPU...")
    
    # 2. Formulate Barrett Bounds and encode
    P_data = []
    M_data = []
    E_bits = []
    
    max_bits = 0
    e_vals = []
    
    for q, P in candidates:
        # Barrett approximation: M = floor(128^(2 * L) / P)
        M = (1 << (7 * 2 * L_DIGITS)) // P
        
        P_data.append(encode_base128(P, N_SIZE))
        M_data.append(encode_base128(M, N_SIZE))
        
        E = P - 1
        e_vals.append(E)
        bits = E.bit_length()
        if bits > max_bits:
            max_bits = bits
            
    for E in e_vals:
        # Extract bits (little endian for the GPU loop)
        bits = []
        for i in range(max_bits):
            bits.append((E >> i) & 1)
        E_bits.append(bits)
        
    print(f"[*] Max bits in E: {max_bits}. Generating binary batch payload...")
    
    # 3. Write arrays in standard layout
    with open("batch.bin", "wb") as f:
        f.write(b"PRM2")
        f.write(struct.pack("<I", BATCH_SIZE))
        f.write(struct.pack("<I", N_SIZE))
        f.write(struct.pack("<I", max_bits))
        
        # Write P_data standard
        for batch in range(BATCH_SIZE):
            for i in range(N_SIZE):
                f.write(struct.pack("<I", P_data[batch][i]))
                
        # Write M_data standard
        for batch in range(BATCH_SIZE):
            for i in range(N_SIZE):
                f.write(struct.pack("<I", M_data[batch][i]))
                
        # Write E_bits standard
        for batch in range(BATCH_SIZE):
            for i in range(max_bits):
                f.write(struct.pack("<B", E_bits[batch][i]))
                
    print("[+] Wrote 7.3 MB binary payload to batch.bin!")
    print("[*] Handoff to integrated CUDA binary ready.")

if __name__ == "__main__":
    main()
