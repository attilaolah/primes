#pragma once
#include <stdint.h>
#include <cuda_runtime.h>

// Coalesced comparison and subtraction for the final Barrett thresholding.
// In Barrett reduction, the result R can be slightly larger than P (up to 3P).
// We must repeatedly subtract P until R < P.
__global__ void batched_reduce_final(uint32_t *d_R, uint32_t *d_P, int L_digits, int BATCH) {
    int batch_idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (batch_idx < BATCH) {
        for (int iter = 0; iter < 3; iter++) {
            // 1. Compare R and P (starting from most significant digit)
            bool r_ge_p = false;
            for (int i = L_digits; i >= 0; i--) {
                int idx = i * BATCH + batch_idx;
                if (d_R[idx] > d_P[idx]) { r_ge_p = true; break; }
                if (d_R[idx] < d_P[idx]) { r_ge_p = false; break; }
            }
            
            // 2. If R >= P, subtract P from R with borrow propagation
            if (r_ge_p) {
                int64_t borrow = 0;
                for (int i = 0; i <= L_digits; i++) {
                    int idx = i * BATCH + batch_idx;
                    int64_t val = (int64_t)d_R[idx] - d_P[idx] + borrow;
                    
                    if (val < 0) {
                        int64_t b = (127 - val) / 128;
                        val += b * 128;
                        borrow = -b;
                    } else {
                        borrow = val >> 7;
                    }
                    d_R[idx] = val & 127;
                }
            } else {
                break; // Fully reduced
            }
        }
    }
}

// Conditional Multiply by 2 (Left Shift 1 bit)
// This is used for the Square-and-Multiply exponentiation loop when the bit is 1.
__global__ void batched_mul2_cond(uint32_t *d_A, uint32_t *d_P, uint8_t *d_E_bits, int bit_idx, int L_digits, int BATCH) {
    int batch_idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (batch_idx < BATCH) {
        // Only multiply if the exponent bit is 1
        if (d_E_bits[batch_idx * 224000 + bit_idx] == 1) {
            
            // 1. Multiply by 2 (equivalent to Base-128 left shift by 1 bit)
            int64_t carry = 0;
            for (int i = 0; i <= L_digits; i++) {
                int idx = i * BATCH + batch_idx;
                int64_t val = (d_A[idx] << 1) + carry;
                d_A[idx] = val & 127;
                carry = val >> 7;
            }
            
            // 2. Threshold: If A >= P, A = A - P
            bool a_ge_p = false;
            for (int i = L_digits; i >= 0; i--) {
                int idx = i * BATCH + batch_idx;
                if (d_A[idx] > d_P[idx]) { a_ge_p = true; break; }
                if (d_A[idx] < d_P[idx]) { a_ge_p = false; break; }
            }
            
            if (a_ge_p) {
                int64_t borrow = 0;
                for (int i = 0; i <= L_digits; i++) {
                    int idx = i * BATCH + batch_idx;
                    int64_t val = (int64_t)d_A[idx] - d_P[idx] + borrow;
                    if (val < 0) {
                        int64_t b = (127 - val) / 128;
                        val += b * 128;
                        borrow = -b;
                    } else {
                        borrow = val >> 7;
                    }
                    d_A[idx] = val & 127;
                }
            }
        }
    }
}
