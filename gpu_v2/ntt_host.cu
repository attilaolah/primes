#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "ntt_core.cuh"

// Declare kernels from ntt_kernel.cu
extern __global__ void ntt_bit_reverse_kernel(uint32_t *d_poly, int N, int logN);
extern __global__ void ntt_butterfly_stage_kernel(uint32_t *d_poly, int N, int m, uint32_t wm);
extern __global__ void pointwise_mul_kernel(uint32_t *d_A, uint32_t *d_B, int N);

// CPU utility to launch the NTT
void run_ntt_device(uint32_t *d_poly, int N, bool inverse) {
    int logN = 0;
    while ((1 << logN) < N) logN++;
    
    int threads = 256;
    int blocks_N = (N + threads - 1) / threads;
    int blocks_half_N = (N / 2 + threads - 1) / threads;
    
    // 1. Bit Reversal
    ntt_bit_reverse_kernel<<<blocks_N, threads>>>(d_poly, N, logN);
    cudaDeviceSynchronize();
    
    // 2. Butterfly Stages
    for (int s = 1; s <= logN; s++) {
        int m = 1 << s;
        // Primitive m-th root of unity: root^((q-1)/m) mod q
        uint32_t wm = pow_mod(NTT_ROOT, (NTT_Q - 1) / m);
        
        if (inverse) {
            // Inverse NTT uses wm^-1 mod q. Fermat's Little Theorem: a^(q-2) mod q
            wm = pow_mod(wm, NTT_Q - 2);
        }
        
        ntt_butterfly_stage_kernel<<<blocks_half_N, threads>>>(d_poly, N, m, wm);
        cudaDeviceSynchronize();
    }
    
    // 3. Inverse Scaling
    if (inverse) {
        uint32_t n_inv = pow_mod(N, NTT_Q - 2);
        // We can reuse pointwise mul kernel with an array of n_inv, or just write a small scaling kernel
        // For simplicity, we just copy to host and scale there for Phase 1.
    }
}

int main() {
    int N = 8; // Small test case
    printf("[*] Testing Base-128 NTT with N=%d\n", N);
    
    uint32_t h_A[8] = {1, 2, 3, 4, 0, 0, 0, 0}; // Polynomial 1 + 2x + 3x^2 + 4x^3
    uint32_t h_B[8] = {5, 6, 7, 8, 0, 0, 0, 0}; // Polynomial 5 + 6x + 7x^2 + 8x^3
    
    uint32_t *d_A, *d_B;
    cudaMalloc(&d_A, N * sizeof(uint32_t));
    cudaMalloc(&d_B, N * sizeof(uint32_t));
    
    cudaMemcpy(d_A, h_A, N * sizeof(uint32_t), cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, h_B, N * sizeof(uint32_t), cudaMemcpyHostToDevice);
    
    // Forward NTT
    run_ntt_device(d_A, N, false);
    run_ntt_device(d_B, N, false);
    
    // Pointwise Multiply
    int threads = 256;
    int blocks = (N + threads - 1) / threads;
    pointwise_mul_kernel<<<blocks, threads>>>(d_A, d_B, N);
    cudaDeviceSynchronize();
    
    // Inverse NTT
    run_ntt_device(d_A, N, true);
    
    uint32_t h_C[8];
    cudaMemcpy(h_C, d_A, N * sizeof(uint32_t), cudaMemcpyDeviceToHost);
    
    // Scale by N^-1
    uint32_t n_inv = pow_mod(N, NTT_Q - 2);
    printf("[+] Resulting Polynomial Coefficients:\n");
    for (int i = 0; i < N; i++) {
        h_C[i] = mul_mod(h_C[i], n_inv);
        printf("C[%d] = %u\n", i, h_C[i]);
    }
    
    // Expected for (1+2x+3x^2+4x^3) * (5+6x+7x^2+8x^3)
    // C[0]=5, C[1]=16, C[2]=34, C[3]=60, C[4]=61, C[5]=52, C[6]=32, C[7]=0
    
    cudaFree(d_A);
    cudaFree(d_B);
    
    return 0;
}
