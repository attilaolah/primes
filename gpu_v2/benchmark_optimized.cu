#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <sys/time.h>
#include "ntt_core.cuh"

#define BATCH_SIZE 128
#define N 65536
#define N_SQRT 256

// ---------------------------------------------------------------------------
// 1. Precalculated Twiddle Factors
// ---------------------------------------------------------------------------
__global__ void init_twiddles(uint32_t *d_twiddles_fwd, uint32_t *d_twiddles_inv) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N) {
        uint32_t wn_fwd = pow_mod(NTT_ROOT, (NTT_Q - 1) / N);
        uint32_t wn_inv = pow_mod(wn_fwd, NTT_Q - 2);
        
        d_twiddles_fwd[i] = pow_mod(wn_fwd, i);
        d_twiddles_inv[i] = pow_mod(wn_inv, i);
    }
}

// ---------------------------------------------------------------------------
// 2. Shared Memory NTT (N=256)
// ---------------------------------------------------------------------------
__device__ void ntt_256_shared(uint32_t *s_poly, uint32_t *d_twiddles) {
    int tid = threadIdx.x;
    
    // Bit-reversal for N=256
    uint32_t i = tid * 2;
    uint32_t rev_i = 0, rev_i1 = 0;
    #pragma unroll
    for (int b = 0; b < 8; b++) {
        rev_i = (rev_i << 1) | ((i >> b) & 1);
        rev_i1 = (rev_i1 << 1) | (((i + 1) >> b) & 1);
    }
    
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
    
    // 8 Stages of Cooley-Tukey
    #pragma unroll
    for (int s = 1; s <= 8; s++) {
        int m = 1 << s;
        int half_m = m / 2;
        
        int group = tid / half_m;
        int j = tid % half_m;
        int k = group * m;
        
        // Lookup twiddle. We need w = W_{m}^{j} = W_N^{j * (N/m)}
        // For N=256, W_256^{j * (256/m)}. Since d_twiddles is size N=65536,
        // we scale up to the full N dimension: 65536 / m
        uint32_t w = d_twiddles[j * (N / m)];
        
        int idx1 = k + j;
        int idx2 = k + j + half_m;
        
        uint32_t u = s_poly[idx1];
        uint32_t t = mul_mod(w, s_poly[idx2]);
        
        s_poly[idx1] = add_mod(u, t);
        s_poly[idx2] = sub_mod(u, t);
        
        __syncthreads();
    }
}

// ---------------------------------------------------------------------------
// 3. Matrix NTT Components
// ---------------------------------------------------------------------------
__global__ void batched_matrix_transpose(uint32_t *d_poly) {
    __shared__ uint32_t tile[32][33];
    int batch_idx = blockIdx.z;
    int x = blockIdx.x * 32 + threadIdx.x;
    int y = blockIdx.y * 32 + threadIdx.y;
    int offset = batch_idx * N;
    
    if (x < N_SQRT && y < N_SQRT) {
        tile[threadIdx.y][threadIdx.x] = d_poly[offset + y * N_SQRT + x];
    }
    __syncthreads();
    
    x = blockIdx.y * 32 + threadIdx.x;
    y = blockIdx.x * 32 + threadIdx.y;
    
    if (x < N_SQRT && y < N_SQRT) {
        d_poly[offset + y * N_SQRT + x] = tile[threadIdx.x][threadIdx.y];
    }
}

__global__ void batched_ntt_256_rows(uint32_t *d_poly, uint32_t *d_twiddles, bool do_matrix_twiddle) {
    int batch_idx = blockIdx.y;
    int row_idx = blockIdx.x;
    int tid = threadIdx.x;
    __shared__ uint32_t s_poly[256];
    
    int offset = batch_idx * N + row_idx * 256;
    s_poly[tid] = d_poly[offset + tid];
    s_poly[tid + 128] = d_poly[offset + tid + 128];
    __syncthreads();
    
    ntt_256_shared(s_poly, d_twiddles);
    __syncthreads();
    
    if (do_matrix_twiddle) {
        // Apply Six-Step matrix twiddle: W_N^{row_idx * col_idx}
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
    
    if (do_forward) {
        batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, d_twiddles, true);
        batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, d_twiddles, false);
        batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
    } else {
        batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, d_twiddles, false);
        batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
        batched_ntt_256_rows<<<ntt_blocks, ntt_threads, 0, stream>>>(d_poly, d_twiddles, true);
        batched_matrix_transpose<<<t_blocks, t_threads, 0, stream>>>(d_poly);
    }
}

// ---------------------------------------------------------------------------
// 4. Coalesced Carry Propagation
// ---------------------------------------------------------------------------
__global__ void transpose_batch_forward(uint32_t *d_poly, uint32_t *d_transposed) {
    __shared__ uint32_t tile[32][33];
    int x = blockIdx.x * 32 + threadIdx.x; 
    int y = blockIdx.y * 32 + threadIdx.y; 
    if (x < N && y < BATCH_SIZE) {
        tile[threadIdx.y][threadIdx.x] = d_poly[y * N + x];
    }
    __syncthreads();
    
    int trans_x = blockIdx.y * 32 + threadIdx.x; 
    int trans_y = blockIdx.x * 32 + threadIdx.y; 
    if (trans_x < BATCH_SIZE && trans_y < N) {
        d_transposed[trans_y * BATCH_SIZE + trans_x] = tile[threadIdx.x][threadIdx.y];
    }
}

__global__ void transpose_batch_backward(uint32_t *d_transposed, uint32_t *d_poly) {
    __shared__ uint32_t tile[32][33];
    int x = blockIdx.x * 32 + threadIdx.x; 
    int y = blockIdx.y * 32 + threadIdx.y; 
    if (x < BATCH_SIZE && y < N) {
        tile[threadIdx.y][threadIdx.x] = d_transposed[y * BATCH_SIZE + x];
    }
    __syncthreads();
    
    int trans_x = blockIdx.y * 32 + threadIdx.x; 
    int trans_y = blockIdx.x * 32 + threadIdx.y; 
    if (trans_x < N && trans_y < BATCH_SIZE) {
        d_poly[trans_y * N + trans_x] = tile[threadIdx.x][threadIdx.y];
    }
}

__global__ void batched_carry_propagate_coalesced(uint32_t *d_transposed) {
    int batch_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (batch_idx < BATCH_SIZE) {
        uint64_t carry = 0;
        #pragma unroll 1
        for (int i = 0; i < N; i++) {
            int idx = i * BATCH_SIZE + batch_idx;
            uint64_t val = d_transposed[idx] + carry;
            d_transposed[idx] = val & 127;
            carry = val >> 7;
        }
    }
}

__global__ void batched_pointwise_sqr(uint32_t *d_A, uint32_t *d_X) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N) {
        d_X[tid] = mul_mod(d_A[tid], d_A[tid]);
    }
}

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main() {
    printf("[*] GPU V2 OPTIMIZED Hardware Pipeline Benchmark\n");
    printf("[*] Pre-cached Twiddle Factors (O(1) lookups)\n");
    
    size_t mem_size = BATCH_SIZE * N * sizeof(uint32_t);
    uint32_t *d_A, *d_X, *d_transposed, *d_twiddles_fwd, *d_twiddles_inv;
    cudaMalloc(&d_A, mem_size);
    cudaMalloc(&d_X, mem_size);
    cudaMalloc(&d_transposed, mem_size);
    cudaMalloc(&d_twiddles_fwd, N * sizeof(uint32_t));
    cudaMalloc(&d_twiddles_inv, N * sizeof(uint32_t));
    
    // Pre-calculate twiddle arrays
    int threads_init = 256;
    int blocks_init = (N + threads_init - 1) / threads_init;
    init_twiddles<<<blocks_init, threads_init>>>(d_twiddles_fwd, d_twiddles_inv);
    cudaDeviceSynchronize();
    
    cudaStream_t stream;
    cudaStreamCreate(&stream);
    
    dim3 t_threads(32, 32, 1);
    dim3 t_blocks_fwd(N / 32, BATCH_SIZE / 32, 1);
    dim3 t_blocks_bwd(BATCH_SIZE / 32, N / 32, 1);
    
    cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);
    
    // 1 Full Squaring Operation
    launch_matrix_ntt(d_A, d_twiddles_fwd, true, stream);
    
    int threads = 256;
    int blocks = (BATCH_SIZE * N + threads - 1) / threads;
    batched_pointwise_sqr<<<blocks, threads, 0, stream>>>(d_A, d_X);
    
    launch_matrix_ntt(d_X, d_twiddles_inv, false, stream);
    
    // Carry Propagation Coalesced
    transpose_batch_forward<<<t_blocks_fwd, t_threads, 0, stream>>>(d_X, d_transposed);
    
    int cp_threads = 128;
    int cp_blocks = (BATCH_SIZE + cp_threads - 1) / cp_threads;
    batched_carry_propagate_coalesced<<<cp_blocks, cp_threads, 0, stream>>>(d_transposed);
    
    transpose_batch_backward<<<t_blocks_bwd, t_threads, 0, stream>>>(d_transposed, d_X);
    
    cudaGraph_t graph;
    cudaStreamEndCapture(stream, &graph);
    
    cudaGraphExec_t graphExec;
    cudaGraphInstantiate(&graphExec, graph, NULL, NULL, 0);
    
    int test_ops = 500;
    
    printf("[*] Running %d full hardware-optimized exponentiation iterations...\n", test_ops);
    double start = get_time();
    for(int i = 0; i < test_ops; i++) {
        cudaGraphLaunch(graphExec, stream);
    }
    cudaStreamSynchronize(stream);
    double elapsed = get_time() - start;
    
    double ms_per_sqr = (elapsed * 1000.0) / test_ops;
    
    // In Barrett, 1 Fermat step = 3 squarings/multiplications
    double ms_per_barrett_step = ms_per_sqr * 3;
    double projected_sec = (ms_per_barrett_step * 223616) / 1000.0;
    
    printf("[+] Time for 1 Optimized Squaring (Batch 128): %.2f ms\n", ms_per_sqr);
    printf("[+] Projected Wall-Clock for Fermat Test: %.2f hours\n", projected_sec / 3600.0);
    printf("[+] Amortized Time per Candidate: %.2f seconds\n", projected_sec / BATCH_SIZE);
    
    return 0;
}
