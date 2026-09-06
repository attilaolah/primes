#pragma once
#include <stdint.h>
#include <cuda_runtime.h>

// ---------------------------------------------------------------------------
// GPU V2 NTT Core Math
// ---------------------------------------------------------------------------
// We use a 32-bit prime: q = 2013265921 (which is 15 * 2^27 + 1).
// This allows us to do exact pointwise multiplication in standard 64-bit uints:
// C = (uint64_t)A * B % q. (No 128-bit assembly required!).
//
// To prevent overflow during the polynomial multiplication (where the max uncarried
// value is N * (base-1)^2), we represent the big integer in Base 128 (7-bit chunks).
// For N = 32768 (which supports numbers up to 229,000 bits), the max value is:
// 32768 * 127 * 127 = 528,482,304, which safely fits under q = 2,013,265,921.

#define NTT_Q 2013265921ULL
#define NTT_ROOT 31ULL  // A primitive root modulo q

__device__ __host__ inline uint32_t add_mod(uint32_t a, uint32_t b) {
    uint32_t sum = a + b;
    return (sum >= NTT_Q) ? (sum - NTT_Q) : sum;
}

__device__ __host__ inline uint32_t sub_mod(uint32_t a, uint32_t b) {
    return (a < b) ? (a + NTT_Q - b) : (a - b);
}

__device__ __host__ inline uint32_t mul_mod(uint32_t a, uint32_t b) {
    return (uint32_t)(((uint64_t)a * b) % NTT_Q);
}

__device__ __host__ inline uint32_t pow_mod(uint32_t base, uint32_t exp) {
    uint32_t res = 1;
    base = base % NTT_Q;
    while (exp > 0) {
        if (exp % 2 == 1) res = mul_mod(res, base);
        base = mul_mod(base, base);
        exp /= 2;
    }
    return res;
}
