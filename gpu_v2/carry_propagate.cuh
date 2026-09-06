#pragma once
#include <stdint.h>
#include <cuda_runtime.h>

// This kernel transposes the N x BATCH_SIZE matrix so that BATCH elements
// are contiguous in memory. This turns the O(N) sequential carry propagation
// into perfectly coalesced memory reads!
__global__ void transpose_batch_forward(uint32_t *d_poly, uint32_t *d_transposed, int N_size, int BATCH) {
    // Standard out-of-place tile transpose could be used, but since BATCH is 128
    // we can use a simple 32x32 shared memory tile.
    __shared__ uint32_t tile[32][33];
    
    int x = blockIdx.x * 32 + threadIdx.x; // Col (0 to N)
    int y = blockIdx.y * 32 + threadIdx.y; // Row (0 to BATCH)
    
    if (x < N_size && y < BATCH) {
        tile[threadIdx.y][threadIdx.x] = d_poly[y * N_size + x];
    }
    __syncthreads();
    
    int trans_x = blockIdx.y * 32 + threadIdx.x; // Col (0 to BATCH)
    int trans_y = blockIdx.x * 32 + threadIdx.y; // Row (0 to N)
    
    if (trans_x < BATCH && trans_y < N_size) {
        d_transposed[trans_y * BATCH + trans_x] = tile[threadIdx.x][threadIdx.y];
    }
}

__global__ void batched_carry_propagate_coalesced(uint32_t *d_transposed, int N_size, int BATCH) {
    int batch_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (batch_idx < BATCH) {
        uint64_t carry = 0;
        
        #pragma unroll 1
        for (int i = 0; i < N_size; i++) {
            // PERFECTLY COALESCED! Adjacent threads read adjacent memory (batch_idx)
            int idx = i * BATCH + batch_idx;
            uint64_t val = d_transposed[idx] + carry;
            d_transposed[idx] = val & 127;
            carry = val >> 7;
        }
    }
}
