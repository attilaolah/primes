#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "ntt_core.cuh"

// We need N=65536 because a 224,000 bit number = 31,945 base-128 coefficients.
// Multiplying two 32k polynomials yields a 64k polynomial.
#define N 65536
#define LOG_N 16
#define BATCH_SIZE 128 // Process 128 candidates simultaneously to hide CPU launch overhead

// Bit-reversal permutation (Batched)
__device__ uint32_t reverse_bits(uint32_t x, int bits) {
    uint32_t res = 0;
    for (int i = 0; i < bits; i++) {
        res = (res << 1) | (x & 1);
        x >>= 1;
    }
    return res;
}

__global__ void batched_bit_reverse(uint32_t *d_poly) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int batch_idx = tid / N;
    int i = tid % N;
    
    if (batch_idx < BATCH_SIZE) {
        uint32_t rev = reverse_bits(i, LOG_N);
        if (i < rev) {
            int idx1 = batch_idx * N + i;
            int idx2 = batch_idx * N + rev;
            uint32_t temp = d_poly[idx1];
            d_poly[idx1] = d_poly[idx2];
            d_poly[idx2] = temp;
        }
    }
}

// Batched Butterfly Stage
__global__ void batched_butterfly_stage(uint32_t *d_poly, int m, uint32_t wm) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int total_butterflies = BATCH_SIZE * (N / 2);
    
    if (tid < total_butterflies) {
        int batch_idx = tid / (N / 2);
        int local_tid = tid % (N / 2);
        
        int half_m = m / 2;
        int group = local_tid / half_m;
        int j = local_tid % half_m;
        int k = group * m;
        
        uint32_t w = pow_mod(wm, j);
        
        int idx1 = batch_idx * N + k + j;
        int idx2 = batch_idx * N + k + j + half_m;
        
        uint32_t u = d_poly[idx1];
        uint32_t t = mul_mod(w, d_poly[idx2]);
        
        d_poly[idx1] = add_mod(u, t);
        d_poly[idx2] = sub_mod(u, t);
    }
}

// Batched Pointwise Multiply
__global__ void batched_pointwise_mul(uint32_t *d_A, uint32_t *d_B) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N) {
        d_A[tid] = mul_mod(d_A[tid], d_B[tid]);
    }
}

// CPU Orchestrator
void run_batched_ntt(uint32_t *d_poly, bool inverse) {
    int threads = 256;
    int blocks_N = (BATCH_SIZE * N + threads - 1) / threads;
    int blocks_half_N = (BATCH_SIZE * (N / 2) + threads - 1) / threads;
    
    batched_bit_reverse<<<blocks_N, threads>>>(d_poly);
    
    for (int s = 1; s <= LOG_N; s++) {
        int m = 1 << s;
        uint32_t wm = pow_mod(NTT_ROOT, (NTT_Q - 1) / m);
        if (inverse) wm = pow_mod(wm, NTT_Q - 2);
        
        batched_butterfly_stage<<<blocks_half_N, threads>>>(d_poly, m, wm);
    }
}

int main() {
    printf("[*] GPU V2 Benchmark: Batched NTT Multiplier\n");
    printf("[*] Configuration: N = %d, Bits = ~224k, Batch Size = %d\n", N, BATCH_SIZE);
    
    size_t mem_size = BATCH_SIZE * N * sizeof(uint32_t);
    uint32_t *d_A, *d_B;
    cudaMalloc(&d_A, mem_size);
    cudaMalloc(&d_B, mem_size);
    
    // Warmup
    run_batched_ntt(d_A, false);
    
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    
    int iterations = 10;
    cudaEventRecord(start);
    
    for (int i = 0; i < iterations; i++) {
        run_batched_ntt(d_A, false);
        run_batched_ntt(d_B, false);
        
        int threads = 256;
        int blocks = (BATCH_SIZE * N + threads - 1) / threads;
        batched_pointwise_mul<<<blocks, threads>>>(d_A, d_B);
        
        run_batched_ntt(d_A, true);
    }
    
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    
    float milliseconds = 0;
    cudaEventElapsedTime(&milliseconds, start, stop);
    
    float ms_per_batch = milliseconds / iterations;
    float ms_per_mul = ms_per_batch / BATCH_SIZE;
    
    printf("[+] Time for 1 Full Multiplication (NTT + iNTT): %.3f ms\n", ms_per_mul);
    
    // Fermat Test requires ~223,616 squarings/multiplications
    int fermat_ops = 223616;
    float expected_fermat_sec = (ms_per_mul * fermat_ops) / 1000.0f;
    
    printf("[+] Projected GPU Time per Fermat Test: %.2f seconds (%.2f minutes)\n", expected_fermat_sec, expected_fermat_sec / 60.0f);
    
    cudaFree(d_A);
    cudaFree(d_B);
    
    return 0;
}
