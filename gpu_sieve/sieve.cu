#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <cuda_runtime.h>

__global__ void compute_bad_qs(
    const uint32_t *base_limbs, int num_limbs,
    const uint64_t *primes, int num_primes,
    uint8_t *is_q_bad, uint64_t q_start, uint32_t N
) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_primes) return;

    uint64_t p = primes[tid];
    if (p == 2) return; // Handled dynamically

    // Compute B = base % p
    uint64_t B = 0;
    for (int j = num_limbs - 1; j >= 0; j--) {
        B = (B << 16) % p;
        B = (B << 16) % p;
        B = (B + base_limbs[j]) % p;
    }

    if (B == 0) return; // base is divisible by p, skip

    // Compute inverse of B mod p via Extended Euclidean Algorithm
    int64_t t = 0, newt = 1;
    int64_t r = p, newr = B;
    while (newr != 0) {
        int64_t quotient = r / newr;
        int64_t temp = t; t = newt; newt = temp - quotient * newt;
        temp = r; r = newr; newr = temp - quotient * newr;
    }
    if (t < 0) t += p;
    uint64_t inv = t;

    // R_p = -B^{-1} mod p
    uint64_t R_p = p - inv;

    // q = q_start + 2k. We want q = R_p mod p
    // 2k = R_p - q_start mod p
    uint64_t diff = (R_p + p - (q_start % p)) % p;
    uint64_t two_inv = (p + 1) / 2;
    uint64_t k0 = (diff * two_inv) % p;

    for (uint64_t k = k0; k < N; k += p) {
        is_q_bad[k] = 1;
    }
}

int main() {
    FILE *f = fopen("sieve_input.bin", "rb");
    if (!f) {
        printf("[-] Failed to open sieve_input.bin\n");
        return 1;
    }
    
    uint32_t num_limbs, num_primes, N;
    uint64_t q_start;
    fread(&num_limbs, 4, 1, f);
    fread(&num_primes, 4, 1, f);
    fread(&N, 4, 1, f);
    fread(&q_start, 8, 1, f);
    
    uint32_t *h_base_limbs = (uint32_t*)malloc(num_limbs * 4);
    uint64_t *h_primes = (uint64_t*)malloc(num_primes * 8);
    uint8_t *h_is_q_bad = (uint8_t*)calloc(N, 1);
    
    fread(h_base_limbs, 4, num_limbs, f);
    fread(h_primes, 8, num_primes, f);
    fclose(f);
    
    uint32_t *d_base_limbs;
    uint64_t *d_primes;
    uint8_t *d_is_q_bad;
    
    cudaMalloc(&d_base_limbs, num_limbs * 4);
    cudaMalloc(&d_primes, num_primes * 8);
    cudaMalloc(&d_is_q_bad, N);
    
    cudaMemcpy(d_base_limbs, h_base_limbs, num_limbs * 4, cudaMemcpyHostToDevice);
    cudaMemcpy(d_primes, h_primes, num_primes * 8, cudaMemcpyHostToDevice);
    cudaMemset(d_is_q_bad, 0, N);
    
    int block_size = 256;
    int num_blocks = (num_primes + block_size - 1) / block_size;
    
    compute_bad_qs<<<num_blocks, block_size>>>(d_base_limbs, num_limbs, d_primes, num_primes, d_is_q_bad, q_start, N);
    cudaDeviceSynchronize();
    
    cudaMemcpy(h_is_q_bad, d_is_q_bad, N, cudaMemcpyDeviceToHost);
    
    FILE *out = fopen("sieve_output.bin", "wb");
    fwrite(h_is_q_bad, 1, N, out);
    fclose(out);
    
    // Cleanup
    cudaFree(d_base_limbs);
    cudaFree(d_primes);
    cudaFree(d_is_q_bad);
    free(h_base_limbs);
    free(h_primes);
    free(h_is_q_bad);
    
    return 0;
}
