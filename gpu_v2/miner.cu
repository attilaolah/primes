#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <cuda_runtime.h>
#include "ntt_core.cuh"
#include "ntt_shared.cuh"
#include "carry_propagate.cuh"
#include "barrett_reduce.cuh"
#include "barrett_core.cuh"

// For accurate timing
#include <sys/time.h>
double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

// Ensure dimensions are correct
#define BATCH_SIZE 128
#define N_SIZE 65536
#define L_DIGITS 31945

// Matrix NTT
__global__ void batched_matrix_transpose(uint32_t *d_poly) {
    __shared__ uint32_t tile[32][33];
    int batch_idx = blockIdx.z;
    int x = blockIdx.x * 32 + threadIdx.x;
    int y = blockIdx.y * 32 + threadIdx.y;
    int offset = batch_idx * N_SIZE;
    if (x < 256 && y < 256) tile[threadIdx.y][threadIdx.x] = d_poly[offset + y * 256 + x];
    __syncthreads();
    x = blockIdx.y * 32 + threadIdx.x;
    y = blockIdx.x * 32 + threadIdx.y;
    if (x < 256 && y < 256) d_poly[offset + y * 256 + x] = tile[threadIdx.x][threadIdx.y];
}

__global__ void batched_ntt_256_rows(uint32_t *d_poly, uint32_t *d_twiddles, bool do_matrix_twiddle) {
    int batch_idx = blockIdx.y;
    int row_idx = blockIdx.x;
    int tid = threadIdx.x;
    __shared__ uint32_t s_poly[256];
    int offset = batch_idx * N_SIZE + row_idx * 256;
    
    s_poly[tid] = d_poly[offset + tid];
    s_poly[tid + 128] = d_poly[offset + tid + 128];
    __syncthreads();
    
    ntt_256_shared(s_poly, d_twiddles);
    __syncthreads();
    
    if (do_matrix_twiddle) {
        uint32_t w1 = d_twiddles[row_idx * tid];
        uint32_t w2 = d_twiddles[row_idx * (tid + 128)];
        s_poly[tid] = mul_mod(s_poly[tid], w1);
        s_poly[tid + 128] = mul_mod(s_poly[tid + 128], w2);
    }
    
    d_poly[offset + tid] = s_poly[tid];
    d_poly[offset + tid + 128] = s_poly[tid + 128];
}

void launch_matrix_ntt(uint32_t *d_poly, uint32_t *d_twiddles, bool do_forward, cudaStream_t stream) {
    dim3 t_threads(32, 32, 1);
    dim3 t_blocks(256 / 32, 256 / 32, BATCH_SIZE);
    dim3 ntt_threads(128, 1, 1);
    dim3 ntt_blocks(256, BATCH_SIZE, 1);
    
    batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
    batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, d_twiddles, do_forward);
    batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
    batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, d_twiddles, !do_forward);
    batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
}

// ---------------------------------------------------------------------------
// Precalculated Twiddle Factors
// ---------------------------------------------------------------------------
__global__ void init_twiddles(uint32_t *d_twiddles_fwd, uint32_t *d_twiddles_inv) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N_SIZE) {
        uint32_t wn_fwd = pow_mod(NTT_ROOT, (NTT_Q - 1) / N_SIZE);
        uint32_t wn_inv = pow_mod(wn_fwd, NTT_Q - 2);
        d_twiddles_fwd[i] = pow_mod(wn_fwd, i);
        d_twiddles_inv[i] = pow_mod(wn_inv, i);
    }
}

// ---------------------------------------------------------------------------
// Standard Layout Barrett Kernels
// ---------------------------------------------------------------------------
__global__ void batched_pointwise_sqr(uint32_t *d_A, uint32_t *d_X) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N_SIZE) d_X[tid] = mul_mod(d_A[tid], d_A[tid]);
}

__global__ void batched_pointwise_mul(uint32_t *d_A, uint32_t *d_B, uint32_t *d_X) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N_SIZE) d_X[tid] = mul_mod(d_A[tid], d_B[tid]);
}

__global__ void batched_shift_right(uint32_t *d_out, uint32_t *d_in, int shift) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N_SIZE) {
        int batch = tid / N_SIZE;
        int i = tid % N_SIZE;
        if (i + shift < N_SIZE) d_out[tid] = d_in[batch * N_SIZE + i + shift];
        else d_out[tid] = 0;
    }
}

__global__ void batched_mod_base(uint32_t *d_out, uint32_t *d_in, int keep) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N_SIZE) {
        int i = tid % N_SIZE;
        if (i < keep) d_out[tid] = d_in[tid];
        else d_out[tid] = 0;
    }
}

__global__ void batched_sub(uint32_t *d_out, uint32_t *d_in1, uint32_t *d_in2) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N_SIZE) d_out[tid] = sub_mod(d_in1[tid], d_in2[tid]);
}

// ---------------------------------------------------------------------------
// Coalesced Carry Propagation (Requires Transpose)
// ---------------------------------------------------------------------------
void carry_propagate_standard(uint32_t *d_poly, uint32_t *d_trans, cudaStream_t stream) {
    dim3 t_threads(32, 32, 1);
    dim3 t_blocks_fwd(N_SIZE / 32, BATCH_SIZE / 32, 1);
    dim3 t_blocks_bwd(BATCH_SIZE / 32, N_SIZE / 32, 1);
    
    transpose_batch_forward<<<t_blocks_fwd, t_threads, 0, stream>>>(d_poly, d_trans, N_SIZE, BATCH_SIZE);
    
    int cp_threads = 128;
    int cp_blocks = (BATCH_SIZE + cp_threads - 1) / cp_threads;
    batched_carry_propagate_coalesced<<<cp_blocks, cp_threads, 0, stream>>>(d_trans, N_SIZE, BATCH_SIZE);
    
    transpose_batch_backward<<<t_blocks_bwd, t_threads, 0, stream>>>(d_trans, d_poly, N_SIZE, BATCH_SIZE);
}

// ---------------------------------------------------------------------------
// Main Miner Shell
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    if (argc < 2) {
        printf("Usage: %s <batch.bin>\n", argv[0]);
        return 1;
    }
    
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        printf("[-] Failed to open %s\n", argv[1]);
        return 1;
    }
    
    char magic[5] = {0};
    fread(magic, 1, 4, f);
    if (magic[0] != 'P' || magic[1] != 'R' || magic[2] != 'M' || magic[3] != '2') {
        printf("[-] Invalid magic bytes in batch file.\n");
        return 1;
    }
    
    uint32_t batch_size, n_size, max_bits;
    fread(&batch_size, 4, 1, f);
    fread(&n_size, 4, 1, f);
    fread(&max_bits, 4, 1, f);
    
    if (batch_size != BATCH_SIZE || n_size != N_SIZE) {
        printf("[-] Batch size mismatch! Expected %d/%d\n", BATCH_SIZE, N_SIZE);
        return 1;
    }
    
    printf("[*] GPU Miner initialized. Batch: %u, N: %u, Max Bits: %u\n", BATCH_SIZE, N_SIZE, max_bits);
    
    size_t mem_size = BATCH_SIZE * N_SIZE * sizeof(uint32_t);
    uint32_t *h_P = (uint32_t*)malloc(mem_size);
    uint32_t *h_M = (uint32_t*)malloc(mem_size);
    uint8_t *h_E = (uint8_t*)malloc(BATCH_SIZE * max_bits);
    
    fread(h_P, 4, BATCH_SIZE * N_SIZE, f);
    fread(h_M, 4, BATCH_SIZE * N_SIZE, f);
    fread(h_E, 1, BATCH_SIZE * max_bits, f);
    fclose(f);
    
    printf("[+] Successfully loaded 7.3MB payload to Host RAM.\n");
    
    // Allocate Device Memory
    uint32_t *d_A, *d_X, *d_Q1, *d_Q2, *d_Q3, *d_R1, *d_R2, *d_trans;
    cudaMalloc(&d_A, mem_size);
    cudaMalloc(&d_X, mem_size);
    cudaMalloc(&d_Q1, mem_size);
    cudaMalloc(&d_Q2, mem_size);
    cudaMalloc(&d_Q3, mem_size);
    cudaMalloc(&d_R1, mem_size);
    cudaMalloc(&d_R2, mem_size);
    cudaMalloc(&d_trans, mem_size);
    
    uint32_t *d_P, *d_M, *d_P_trans;
    cudaMalloc(&d_P, mem_size);
    cudaMalloc(&d_M, mem_size);
    cudaMalloc(&d_P_trans, mem_size);
    
    uint8_t *d_E;
    cudaMalloc(&d_E, BATCH_SIZE * max_bits);
    
    uint32_t *d_twiddles_fwd, *d_twiddles_inv;
    cudaMalloc(&d_twiddles_fwd, N_SIZE * sizeof(uint32_t));
    cudaMalloc(&d_twiddles_inv, N_SIZE * sizeof(uint32_t));
    
    // Pre-calculate twiddle arrays
    int threads_init = 256;
    int blocks_init = (N_SIZE + threads_init - 1) / threads_init;
    init_twiddles<<<blocks_init, threads_init>>>(d_twiddles_fwd, d_twiddles_inv);
    
    // Copy data
    cudaMemcpy(d_P, h_P, mem_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_M, h_M, mem_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_E, h_E, BATCH_SIZE * max_bits, cudaMemcpyHostToDevice);
    
    cudaStream_t stream;
    cudaStreamCreate(&stream);
    
    dim3 t_threads(32, 32, 1);
    dim3 t_blocks_fwd(N_SIZE / 32, BATCH_SIZE / 32, 1);
    
    // Pre-transpose P and E for coalesced conditional operations
    transpose_batch_forward<<<t_blocks_fwd, t_threads, 0, stream>>>(d_P, d_P_trans, N_SIZE, BATCH_SIZE);
    
    // Convert d_M to NTT domain immediately so we don't have to re-transform it every loop
    launch_matrix_ntt(d_M, d_twiddles_fwd, true, stream);
    
    // Convert d_P to NTT domain as well!
    uint32_t *d_P_ntt;
    cudaMalloc(&d_P_ntt, mem_size);
    cudaMemcpyAsync(d_P_ntt, d_P, mem_size, cudaMemcpyDeviceToDevice, stream);
    launch_matrix_ntt(d_P_ntt, d_twiddles_fwd, true, stream);
    
    // Initialize A = 2
    cudaMemsetAsync(d_A, 0, mem_size, stream);
    // Standard layout: d_A[batch * N + 0] = 2. A simple memset handles 0, we can copy 2 manually
    for (int b = 0; b < BATCH_SIZE; b++) {
        uint32_t val = 2;
        cudaMemcpyAsync(d_A + b * N_SIZE, &val, 4, cudaMemcpyHostToDevice, stream);
    }
    
    int pointwise_blocks = (BATCH_SIZE * N_SIZE + 255) / 256;
    
    printf("[*] Pre-computations finished. GPU is entering Fermat Square-and-Multiply Loop!\n");
    double start_time = get_time();
    
    for (int bit = max_bits - 1; bit >= 0; bit--) {
        // --- BARRETT REDUCTION (3 NTT Multiplications) ---
        // 1. X = A * A
        launch_matrix_ntt(d_A, d_twiddles_fwd, true, stream);
        batched_pointwise_sqr<<<pointwise_blocks, 256, 0, stream>>>(d_A, d_X);
        launch_matrix_ntt(d_X, d_twiddles_inv, false, stream);
        carry_propagate_standard(d_X, d_trans, stream);
        
        // 2. Q1 = X >> (L - 1)
        batched_shift_right<<<pointwise_blocks, 256, 0, stream>>>(d_Q1, d_X, L_DIGITS - 1);
        
        // 3. Q2 = Q1 * M
        launch_matrix_ntt(d_Q1, d_twiddles_fwd, true, stream);
        batched_pointwise_mul<<<pointwise_blocks, 256, 0, stream>>>(d_Q1, d_M, d_Q2);
        launch_matrix_ntt(d_Q2, d_twiddles_inv, false, stream);
        carry_propagate_standard(d_Q2, d_trans, stream);
        
        // 4. Q3 = Q2 >> (L + 1)
        batched_shift_right<<<pointwise_blocks, 256, 0, stream>>>(d_Q3, d_Q2, L_DIGITS + 1);
        
        // 5. R1 = X mod B^(L+1)
        batched_mod_base<<<pointwise_blocks, 256, 0, stream>>>(d_R1, d_X, L_DIGITS + 1);
        
        // 6. R2 = Q3 * P
        launch_matrix_ntt(d_Q3, d_twiddles_fwd, true, stream);
        batched_pointwise_mul<<<pointwise_blocks, 256, 0, stream>>>(d_Q3, d_P_ntt, d_R2);
        launch_matrix_ntt(d_R2, d_twiddles_inv, false, stream);
        carry_propagate_standard(d_R2, d_trans, stream);
        batched_mod_base<<<pointwise_blocks, 256, 0, stream>>>(d_R2, d_R2, L_DIGITS + 1);
        
        // 7. R1 = R1 - R2
        batched_sub<<<pointwise_blocks, 256, 0, stream>>>(d_R1, d_R1, d_R2);
        carry_propagate_standard(d_R1, d_trans, stream); // handles negative borrows
        
        // 8. Final Thresholding against P (Requires Transpose for Coalescence)
        transpose_batch_forward<<<t_blocks_fwd, t_threads, 0, stream>>>(d_R1, d_trans, N_SIZE, BATCH_SIZE);
        int cp_blocks = (BATCH_SIZE + 127) / 128;
        batched_reduce_final<<<cp_blocks, 128, 0, stream>>>(d_trans, d_P_trans, L_DIGITS, BATCH_SIZE);
        
        // 9. Conditional Multiply by 2
        batched_mul2_cond<<<cp_blocks, 128, 0, stream>>>(d_trans, d_P_trans, d_E, bit, L_DIGITS, BATCH_SIZE);
        
        // Restore to standard layout A
        dim3 t_blocks_bwd(BATCH_SIZE / 32, N_SIZE / 32, 1);
        transpose_batch_backward<<<t_blocks_bwd, t_threads, 0, stream>>>(d_trans, d_A, N_SIZE, BATCH_SIZE);
        
        // Print progress every 1000 bits (roughly every minute)
        if (bit % 1000 == 0) {
            cudaStreamSynchronize(stream);
            double elapsed = get_time() - start_time;
            printf("[+] Processed bit %d / %d (%.1f%%) | Elapsed: %.1f sec\n", 
                max_bits - bit, max_bits, 100.0 * (max_bits - bit) / max_bits, elapsed);
            fflush(stdout);
        }
    }
    
    cudaStreamSynchronize(stream);
    printf("[+] Fermat test fully completed for all 128 candidates!\n");
    
    // Copy results back and check for A == 1
    uint32_t *h_A = (uint32_t*)malloc(mem_size);
    cudaMemcpy(h_A, d_A, mem_size, cudaMemcpyDeviceToHost);
    
    int primes_found = 0;
    for (int b = 0; b < BATCH_SIZE; b++) {
        bool is_one = (h_A[b * N_SIZE + 0] == 1);
        for (int i = 1; i < N_SIZE; i++) {
            if (h_A[b * N_SIZE + i] != 0) {
                is_one = false;
                break;
            }
        }
        
        if (is_one) {
            printf("[!!!] PRIME FOUND AT BATCH INDEX %d [!!!]\n", b);
            primes_found++;
        }
    }
    
    if (primes_found == 0) {
        printf("[-] No primes found in this batch.\n");
    }
    
    free(h_A);
    return 0;
}
