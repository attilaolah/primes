#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <sys/time.h>
#include "ntt_core.cuh"
#include "ntt_shared.cuh"

#define BATCH_SIZE 128
#define N 65536
#define N_SQRT 256

// 1. Highly Optimized Coalesced Matrix Transpose (32x32 Tiles)
__global__ void batched_transpose(uint32_t *d_poly) {
    __shared__ uint32_t tile[32][33]; // Padding to avoid bank conflicts
    
    int batch_idx = blockIdx.z;
    int x = blockIdx.x * 32 + threadIdx.x; // Col
    int y = blockIdx.y * 32 + threadIdx.y; // Row
    
    int width = 256;
    int offset = batch_idx * N;
    
    if (x < width && y < width) {
        tile[threadIdx.y][threadIdx.x] = d_poly[offset + y * width + x];
    }
    
    __syncthreads();
    
    x = blockIdx.y * 32 + threadIdx.x; // Transposed Col
    y = blockIdx.x * 32 + threadIdx.y; // Transposed Row
    
    if (x < width && y < width) {
        d_poly[offset + y * width + x] = tile[threadIdx.x][threadIdx.y];
    }
}

// 2. Shared Memory NTT Kernel for Rows
__global__ void batched_ntt_256_rows(uint32_t *d_poly, bool do_twiddle, bool inverse) {
    int batch_idx = blockIdx.y;
    int row_idx = blockIdx.x;
    int tid = threadIdx.x; // 128 threads per block
    
    __shared__ uint32_t s_poly[256];
    
    int offset = batch_idx * N + row_idx * 256;
    
    // Load 256 elements coalesced
    s_poly[tid] = d_poly[offset + tid];
    s_poly[tid + 128] = d_poly[offset + tid + 128];
    __syncthreads();
    
    // Perform N=256 NTT completely in Shared Memory!
    ntt_256_shared(s_poly, inverse);
    __syncthreads();
    
    // Multiply by Twiddle Factors if requested
    if (do_twiddle) {
        uint32_t wn = pow_mod(NTT_ROOT, (NTT_Q - 1) / N);
        if (inverse) wn = pow_mod(wn, NTT_Q - 2);
        
        // Twiddle exponent = row_idx * col_idx
        uint32_t w1 = pow_mod(wn, row_idx * tid);
        uint32_t w2 = pow_mod(wn, row_idx * (tid + 128));
        
        s_poly[tid] = mul_mod(s_poly[tid], w1);
        s_poly[tid + 128] = mul_mod(s_poly[tid + 128], w2);
    }
    
    // Store 256 elements coalesced
    d_poly[offset + tid] = s_poly[tid];
    d_poly[offset + tid + 128] = s_poly[tid + 128];
}

// Host orchestrator
void launch_matrix_ntt(uint32_t *d_poly, bool inverse, cudaStream_t stream) {
    dim3 threads(32, 8, 1);
    dim3 blocks(256 / 32, 256 / 8, BATCH_SIZE);
    
    dim3 ntt_threads(128, 1, 1);
    dim3 ntt_blocks(256, BATCH_SIZE, 1); // 256 rows per candidate
    
    if (!inverse) {
        // Forward Six-Step NTT
        batched_transpose<<<blocks, threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, true, false); // With twiddle
        batched_transpose<<<blocks, threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, false, false);
        batched_transpose<<<blocks, threads, 0, stream>>>(d_poly); // Restore order
    } else {
        // Inverse Six-Step NTT
        batched_transpose<<<blocks, threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, false, true);
        batched_transpose<<<blocks, threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, true, true); // With twiddle
        batched_transpose<<<blocks, threads, 0, stream>>>(d_poly);
    }
}
