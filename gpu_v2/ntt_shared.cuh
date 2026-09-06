#pragma once
#include <stdint.h>
#include <cuda_runtime.h>
#include "ntt_core.cuh"

// ---------------------------------------------------------------------------
// Shared Memory NTT Engine (N=256)
// ---------------------------------------------------------------------------
// A single CUDA Block processes a 256-element NTT entirely inside the ultra-fast
// L1 Shared Memory Cache. This reduces Global Memory reads/writes by 8x.

__device__ void ntt_256_shared(uint32_t *s_poly, uint32_t *d_wm) {
    int tid = threadIdx.x; // Assumes blockDim.x == 128 (processes 256 elements)
    
    // Bit-reversal permutation for 256 elements (8 bits)
    // We launch 128 threads, each handles 2 elements
    uint32_t i = tid * 2;
    uint32_t rev_i = 0, rev_i1 = 0;
    
    // Fast bit reversal for 8 bits
    #pragma unroll
    for (int b = 0; b < 8; b++) {
        rev_i = (rev_i << 1) | ((i >> b) & 1);
        rev_i1 = (rev_i1 << 1) | (((i + 1) >> b) & 1);
    }
    
    // Only swap if i < rev_i
    if (i < rev_i) {
        uint32_t temp = s_poly[i];
        s_poly[i] = s_poly[rev_i];
        s_poly[rev_i] = temp;
    }
    if (i + 1 < rev_i1) {
        uint32_t temp = s_poly[i + 1];
        s_poly[i + 1] = s_poly[rev_i1];
        s_poly[rev_i1] = temp;
    }
    
    __syncthreads();
    
    // 8 Stages of Cooley-Tukey (2^1 to 2^8)
    for (int s = 1; s <= 8; s++) {
        int m = 1 << s;
        int half_m = m / 2;
        
        // Root of unity for N=256
        uint32_t wm = d_wm[s - 1];
        // (inverse check was removed, handled via pre-calculated d_twiddles)
        
        // Each thread processes 1 butterfly
        int group = tid / half_m;
        int j = tid % half_m;
        int k = group * m;
        
        uint32_t w = pow_mod(wm, j);
        
        int idx1 = k + j;
        int idx2 = k + j + half_m;
        
        uint32_t u = s_poly[idx1];
        uint32_t t = mul_mod(w, s_poly[idx2]);
        
        s_poly[idx1] = add_mod(u, t);
        s_poly[idx2] = sub_mod(u, t);
        
        __syncthreads();
    }
}
