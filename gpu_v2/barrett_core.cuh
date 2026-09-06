#pragma once
#include <stdint.h>
#include <cuda_runtime.h>
#include "ntt_core.cuh"

// ---------------------------------------------------------------------------
// GPU V2 Barrett Reduction Architecture
// ---------------------------------------------------------------------------
// To compute C = A (mod P) without division, we use Barrett Reduction in Base-128:
// 1. M = floor(B^(2k) / P)  (Precomputed on CPU, uploaded to GPU)
// 2. Q1 = A >> (k - 1)
// 3. Q2 = Q1 * M            (NTT Multiply #1)
// 4. Q3 = Q2 >> (k + 1)
// 5. R1 = A mod B^(k + 1)
// 6. R2 = (Q3 * P) mod B^(k + 1)  (NTT Multiply #2)
// 7. R = R1 - R2
// 8. If R < 0, R += B^(k + 1)
// 9. While R >= P, R -= P
//
// This file declares the Batched Big Integer operations needed to wire the NTT
// into a complete modular exponentiation loop.

#define BATCH_SIZE 128
#define N 65536
#define LOG_N 16

// 1. Shift Right (Division by B^shift)
// Effectively moves all coefficients to the left by 'shift' indices.
__global__ void batched_shift_right(uint32_t *d_poly, int shift) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int batch_idx = tid / N;
    int i = tid % N;
    
    if (batch_idx < BATCH_SIZE) {
        int idx = batch_idx * N + i;
        if (i + shift < N) {
            d_poly[idx] = d_poly[idx + shift];
        } else {
            d_poly[idx] = 0;
        }
    }
}

// 2. Modulo B^shift (Keep lowest 'shift' coefficients)
__global__ void batched_mod_base(uint32_t *d_poly, int shift) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int batch_idx = tid / N;
    int i = tid % N;
    
    if (batch_idx < BATCH_SIZE) {
        if (i >= shift) {
            d_poly[batch_idx * N + i] = 0;
        }
    }
}

// 3. Batched Subtraction (A = A - B)
__global__ void batched_sub(uint32_t *d_A, uint32_t *d_B) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int batch_idx = tid / N;
    int i = tid % N;
    
    if (batch_idx < BATCH_SIZE) {
        int idx = batch_idx * N + i;
        // Subtraction in base 128 requires borrow propagation
        // For simplicity in Phase 1, we do coefficient-wise subtraction
        // and handle borrow propagation in the carry kernel.
        int32_t diff = (int32_t)d_A[idx] - (int32_t)d_B[idx];
        d_A[idx] = diff; 
    }
}

// 4. Carry & Borrow Propagation
// Since Barrett subtraction can produce negative coefficients, our carry
// propagator must also handle negative borrows!
__global__ void batched_carry_propagate(int32_t *d_poly) {
    int batch_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (batch_idx < BATCH_SIZE) {
        int64_t carry = 0;
        int offset = batch_idx * N;
        
        for (int i = 0; i < N; i++) {
            int64_t val = d_poly[offset + i] + carry;
            
            // Handle negative values (borrow)
            if (val < 0) {
                int64_t borrow = (127 - val) / 128; // Ceil div
                val += borrow * 128;
                carry = -borrow;
            } else {
                carry = val >> 7; // Divide by 128
            }
            
            d_poly[offset + i] = val & 127;
        }
    }
}
