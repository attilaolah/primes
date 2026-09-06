#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <sys/time.h>
#include "ntt_core.cuh"
#include "barrett_core.cuh"

__device__ uint32_t reverse_bits(uint32_t x, int bits) {
    uint32_t res = 0;
    for (int i = 0; i < bits; i++) {
        res = (res << 1) | (x & 1);
        x >>= 1;
    }
    return res;
}

__global__ void batched_bit_reverse(uint32_t *d_poly) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int batch_idx = tid / N;
    int i = tid % N;
    if (batch_idx < BATCH_SIZE) {
        uint32_t rev = reverse_bits(i, LOG_N);
        if (i < rev) {
            int idx1 = batch_idx * N + i;
            int idx2 = batch_idx * N + rev;
            uint32_t temp = d_poly[idx1];
            d_poly[idx1] = d_poly[idx2];
            d_poly[idx2] = temp;
        }
    }
}

__global__ void batched_butterfly_stage(uint32_t *d_poly, int m, uint32_t wm) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int total_butterflies = BATCH_SIZE * (N / 2);
    if (tid < total_butterflies) {
        int batch_idx = tid / (N / 2);
        int local_tid = tid % (N / 2);
        int half_m = m / 2;
        int group = local_tid / half_m;
        int j = local_tid % half_m;
        int k = group * m;
        uint32_t w = pow_mod(wm, j);
        int idx1 = batch_idx * N + k + j;
        int idx2 = batch_idx * N + k + j + half_m;
        uint32_t u = d_poly[idx1];
        uint32_t t = mul_mod(w, d_poly[idx2]);
        d_poly[idx1] = add_mod(u, t);
        d_poly[idx2] = sub_mod(u, t);
    }
}

void launch_ntt(uint32_t *d_poly, bool inverse, cudaStream_t stream) {
    int threads = 256;
    int blocks_N = (BATCH_SIZE * N + threads - 1) / threads;
    int blocks_half_N = (BATCH_SIZE * (N / 2) + threads - 1) / threads;
    
    batched_bit_reverse<<<blocks_N, threads, 0, stream>>>(d_poly);
    for (int s = 1; s <= LOG_N; s++) {
        int m = 1 << s;
        uint32_t wm = pow_mod(NTT_ROOT, (NTT_Q - 1) / m);
        if (inverse) wm = pow_mod(wm, NTT_Q - 2);
        batched_butterfly_stage<<<blocks_half_N, threads, 0, stream>>>(d_poly, m, wm);
    }
}

__global__ void batched_pointwise_sqr(uint32_t *d_A, uint32_t *d_X) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N) {
        d_X[tid] = mul_mod(d_A[tid], d_A[tid]);
    }
}

__global__ void batched_pointwise_mul_out(uint32_t *d_A, uint32_t *d_B, uint32_t *d_C) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N) {
        d_C[tid] = mul_mod(d_A[tid], d_B[tid]);
    }
}

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main() {
    printf("[*] GPU V2 FULL Barrett Exponentiation Loop Benchmark\n");
    
    size_t mem_size = BATCH_SIZE * N * sizeof(uint32_t);
    uint32_t *d_A, *d_X, *d_Q1, *d_Q2, *d_Q3, *d_R1, *d_R2, *d_M_ntt, *d_P_ntt;
    
    cudaMalloc(&d_A, mem_size);
    cudaMalloc(&d_X, mem_size);
    cudaMalloc(&d_Q1, mem_size);
    cudaMalloc(&d_Q2, mem_size);
    cudaMalloc(&d_Q3, mem_size);
    cudaMalloc(&d_R1, mem_size);
    cudaMalloc(&d_R2, mem_size);
    cudaMalloc(&d_M_ntt, mem_size);
    cudaMalloc(&d_P_ntt, mem_size);
    
    cudaStream_t stream;
    cudaStreamCreate(&stream);
    
    int L = 31945; 
    int threads = 256;
    int blocks = (BATCH_SIZE * N + threads - 1) / threads;
    int cp_threads = 128;
    int cp_blocks = (BATCH_SIZE + cp_threads - 1) / cp_threads;
    
    printf("[*] Compiling CUDA Graph for 1 full Barrett reduction...\n");
    cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);
    
    // 1. X = A * A
    launch_ntt(d_A, false, stream);
    batched_pointwise_sqr<<<blocks, threads, 0, stream>>>(d_A, d_X);
    launch_ntt(d_X, true, stream);
    batched_carry_propagate<<<cp_blocks, cp_threads, 0, stream>>>((int32_t*)d_X);
    
    // 2. Q1 = X >> (L - 1)
    cudaMemcpyAsync(d_Q1, d_X, mem_size, cudaMemcpyDeviceToDevice, stream);
    batched_shift_right<<<blocks, threads, 0, stream>>>(d_Q1, L - 1);
    
    // 3. Q2 = Q1 * M
    launch_ntt(d_Q1, false, stream);
    batched_pointwise_mul_out<<<blocks, threads, 0, stream>>>(d_Q1, d_M_ntt, d_Q2);
    launch_ntt(d_Q2, true, stream);
    batched_carry_propagate<<<cp_blocks, cp_threads, 0, stream>>>((int32_t*)d_Q2);
    
    // 4. Q3 = Q2 >> (L + 1)
    cudaMemcpyAsync(d_Q3, d_Q2, mem_size, cudaMemcpyDeviceToDevice, stream);
    batched_shift_right<<<blocks, threads, 0, stream>>>(d_Q3, L + 1);
    
    // 5. R1 = X mod B^(L+1)
    cudaMemcpyAsync(d_R1, d_X, mem_size, cudaMemcpyDeviceToDevice, stream);
    batched_mod_base<<<blocks, threads, 0, stream>>>(d_R1, L + 1);
    
    // 6. R2 = Q3 * P
    launch_ntt(d_Q3, false, stream);
    batched_pointwise_mul_out<<<blocks, threads, 0, stream>>>(d_Q3, d_P_ntt, d_R2);
    launch_ntt(d_R2, true, stream);
    batched_carry_propagate<<<cp_blocks, cp_threads, 0, stream>>>((int32_t*)d_R2);
    batched_mod_base<<<blocks, threads, 0, stream>>>(d_R2, L + 1);
    
    // 7. R1 = R1 - R2
    batched_sub<<<blocks, threads, 0, stream>>>(d_R1, d_R2);
    batched_carry_propagate<<<cp_blocks, cp_threads, 0, stream>>>((int32_t*)d_R1);
    
    cudaMemcpyAsync(d_A, d_R1, mem_size, cudaMemcpyDeviceToDevice, stream);
    
    cudaGraph_t graph;
    cudaStreamEndCapture(stream, &graph);
    
    cudaGraphExec_t graphExec;
    cudaGraphInstantiate(&graphExec, graph, NULL, NULL, 0);
    
    int test_ops = 500;
    printf("[*] Executing %d iterations to calculate amortized throughput...\n", test_ops);
    
    double start_time = get_time();
    for (int i = 0; i < test_ops; i++) {
        cudaGraphLaunch(graphExec, stream);
    }
    cudaStreamSynchronize(stream);
    double elapsed = get_time() - start_time;
    
    double ms_per_loop = (elapsed * 1000.0) / test_ops;
    double projected_sec = (ms_per_loop * 223616) / 1000.0;
    
    printf("[+] Time per Full Barrett Loop (Batch of %d): %.2f ms\n", BATCH_SIZE, ms_per_loop);
    printf("[+] Projected Wall-Clock for Fermat Test: %.2f hours\n", projected_sec / 3600.0);
    printf("[+] Amortized Time per Candidate: %.2f minutes\n", (projected_sec / BATCH_SIZE) / 60.0);
    
    return 0;
}
