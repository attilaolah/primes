#include <cuda_runtime.h>
#include <stdint.h>
#include "ntt_core.cuh"

// ---------------------------------------------------------------------------
// Kernel 1: Bit-Reversal Permutation
// ---------------------------------------------------------------------------
__device__ uint32_t reverse_bits(uint32_t x, int bits) {
    uint32_t res = 0;
    for (int i = 0; i < bits; i++) {
        res = (res << 1) | (x & 1);
        x >>= 1;
    }
    return res;
}

__global__ void ntt_bit_reverse_kernel(uint32_t *d_poly, int N, int logN) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < N) {
        uint32_t rev = reverse_bits(tid, logN);
        if (tid < rev) {
            uint32_t temp = d_poly[tid];
            d_poly[tid] = d_poly[rev];
            d_poly[rev] = temp;
        }
    }
}

// ---------------------------------------------------------------------------
// Kernel 2: Single Stage of Cooley-Tukey Butterfly
// ---------------------------------------------------------------------------
// This kernel executes one stage (s) of the log2(N) stages.
// m = 2^s. There are N/2 butterflies to process.
__global__ void ntt_butterfly_stage_kernel(uint32_t *d_poly, int N, int m, uint32_t wm) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Total butterflies = N / 2
    if (tid < N / 2) {
        int half_m = m / 2;
        int group = tid / half_m;
        int j = tid % half_m;
        
        int k = group * m; // starting index of the group
        
        // Compute w = wm^j (In optimized versions, this is precomputed)
        uint32_t w = pow_mod(wm, j);
        
        int idx1 = k + j;
        int idx2 = k + j + half_m;
        
        uint32_t u = d_poly[idx1];
        uint32_t t = mul_mod(w, d_poly[idx2]);
        
        d_poly[idx1] = add_mod(u, t);
        d_poly[idx2] = sub_mod(u, t);
    }
}

// ---------------------------------------------------------------------------
// Kernel 3: Point-wise Multiplication
// ---------------------------------------------------------------------------
__global__ void pointwise_mul_kernel(uint32_t *d_A, uint32_t *d_B, int N) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < N) {
        d_A[tid] = mul_mod(d_A[tid], d_B[tid]);
    }
}
