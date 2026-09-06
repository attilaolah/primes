# GPU V2: The NTT/FFT Frontier

This directory is the research and development branch for the next generation of GPU mining. 

As discovered in V1, the standard CIOS Montgomery Reduction algorithm operates in $O(N^2)$ time. For 30,000-digit numbers (~3,700 32-bit words), this requires ~14 million memory accesses per multiplication. When thousands of threads execute this simultaneously, it completely saturates the GPU's VRAM bandwidth (The Memory Wall).

To beat the CPU's GMP library, the GPU must abandon $O(N^2)$ and implement an $O(N \log N)$ algorithm: the **Number Theoretic Transform (NTT)**.

## The Mathematical Approach

1. **Polynomial Representation**: 
   Instead of viewing our 30,000-digit Base $K$ as a massive 120,000-bit integer, we split it into an array of smaller coefficients (e.g., 16-bit chunks). We treat this array as a polynomial $A(x)$.
   
2. **The NTT Field**:
   Standard FFT uses floating-point complex numbers, which causes precision loss and floating-point errors on massive integers. NTT solves this by doing the FFT over a finite field $\mathbb{Z}_q$, where $q$ is a "friendly" prime like the Goldilocks prime ($q = 2^{64} - 2^{32} + 1$).

3. **The O(N log N) Magic (Cooley-Tukey)**:
   Instead of cross-multiplying every chunk by every other chunk (which is $O(N^2)$), we run a GPU-parallel Cooley-Tukey butterfly network to evaluate the polynomial at different roots of unity. 
   - Forward NTT on $A \rightarrow \hat{A}$
   - Forward NTT on $B \rightarrow \hat{B}$
   - Pointwise multiply: $\hat{C}_i = \hat{A}_i \cdot \hat{B}_i \pmod q$
   - Inverse NTT on $\hat{C} \rightarrow C$

4. **Carry Propagation**:
   The resulting polynomial $C$ contains the un-carried coefficients of the multiplication. A final fast pass normalizes the carries, giving us the exact same result as a standard multiplication but in a fraction of the time.

## Why this works perfectly on GPUs
- **Shared Memory**: The Cooley-Tukey butterfly algorithm can be broken into perfectly sized chunks that fit entirely inside the SM's ultra-fast L1 Shared Memory (which operates in 1-2 clock cycles, unlike the hundreds of cycles for VRAM).
- **Parallelism**: A single multiplication can be collaboratively processed by an entire Warp (32 threads) or Block (256 threads), rather than forcing 1 thread to do 14 million operations alone.

## Status
- **Phase 1**: Implement and validate a basic GPU NTT multiplier for small test numbers.
- **Phase 2**: Wire the NTT multiplier into the Fermat exponentiation loop.
- **Phase 3**: Unleash it on the 120,000-bit payloads!
