#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <sys/time.h>
#include "ntt_core.cuh"

#define N 65536
#define LOG_N 16
#define BATCH_SIZE 128

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

__global__ void batched_pointwise_mul(uint32_t *d_A, uint32_t *d_B) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < BATCH_SIZE * N) {
        d_A[tid] = mul_mod(d_A[tid], d_B[tid]);
    }
}

void run_batched_ntt(uint32_t *d_poly, bool inverse, cudaStream_t stream) {
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

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main() {
    printf("[*] GPU V2 FULL Fermat Throughput Benchmark (CUDA Graphs)\n");
    printf("[*] Configuration: %d Candidates simultaneously\n", BATCH_SIZE);
    printf("[*] Polynomial Size: N=%d (~224,000 bits per candidate)\n", N);
    
    size_t mem_size = BATCH_SIZE * N * sizeof(uint32_t);
    uint32_t *d_A, *d_B;
    cudaMalloc(&d_A, mem_size);
    cudaMalloc(&d_B, mem_size);
    
    cudaStream_t stream;
    cudaStreamCreate(&stream);
    
    printf("[*] Capturing CUDA execution graph for 1 iteration...\n");
    cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);
    run_batched_ntt(d_A, false, stream);
    run_batched_ntt(d_B, false, stream);
    
    int threads = 256;
    int blocks = (BATCH_SIZE * N + threads - 1) / threads;
    batched_pointwise_mul<<<blocks, threads, 0, stream>>>(d_A, d_B);
    
    run_batched_ntt(d_A, true, stream);
    
    cudaGraph_t graph;
    cudaStreamEndCapture(stream, &graph);
    
    cudaGraphExec_t graphExec;
    cudaGraphInstantiate(&graphExec, graph, NULL, NULL, 0);
    
    int total_ops = 223616;
    int chunk_size = 5000;
    
    printf("[*] Launching %d iterations. This will take ~55 minutes...\n\n", total_ops);
    
    double start_time = get_time();
    int ops_done = 0;
    
    while (ops_done < total_ops) {
        int current_chunk = (total_ops - ops_done < chunk_size) ? (total_ops - ops_done) : chunk_size;
        
        for (int i = 0; i < current_chunk; i++) {
            cudaGraphLaunch(graphExec, stream);
        }
        cudaStreamSynchronize(stream);
        ops_done += current_chunk;
        
        double elapsed = get_time() - start_time;
        double ops_per_sec = ops_done / elapsed;
        double remaining_sec = (total_ops - ops_done) / ops_per_sec;
        
        printf("\r[+] Progress: %6d / %d (%.1f%%) | Elapsed: %02d:%02d | ETA: %02d:%02d", 
               ops_done, total_ops, 100.0 * ops_done / total_ops,
               (int)elapsed / 60, (int)elapsed % 60,
               (int)remaining_sec / 60, (int)remaining_sec % 60);
        fflush(stdout);
    }
    
    double total_time = get_time() - start_time;
    printf("\n\n[*] BOOM! Benchmark Complete.\n");
    printf("[+] Total Wall-Clock Time: %.2f seconds (%.2f minutes)\n", total_time, total_time / 60.0);
    printf("[+] Total Candidates Processed: %d\n", BATCH_SIZE);
    printf("[+] Amortized Time per Candidate: %.2f seconds!\n", total_time / BATCH_SIZE);
    
    cudaFree(d_A);
    cudaFree(d_B);
    cudaStreamDestroy(stream);
    cudaGraphExecDestroy(graphExec);
    cudaGraphDestroy(graph);
    
    return 0;
}
