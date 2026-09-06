#include <stdio.h>
#include <gmp.h>
#include <stdlib.h>
#include <omp.h>
#include <sys/time.h>
#include <time.h>
#include <math.h>

#define MEDIAN_WINDOW 101

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main() {
    FILE *f = fopen("search_input.txt", "r");
    if (!f) return 1;
    char p1_str[50000], p2_str[50000], p3_str[50000];
    long long max_sieve = 5000000000LL;
    if (fscanf(f, "%49999s", p1_str) != 1) { fclose(f); return 1; }
    if (fscanf(f, "%49999s", p2_str) != 1) { fclose(f); return 1; }
    if (fscanf(f, "%49999s", p3_str) != 1) { fclose(f); return 1; }
    if (fscanf(f, "%lld", &max_sieve) != 1) {
        max_sieve = 5000000000LL;
    }
    fclose(f);
    
    mpz_t p1, p2, p3, base;
    mpz_init_set_str(p1, p1_str, 10);
    mpz_init_set_str(p2, p2_str, 10);
    mpz_init_set_str(p3, p3_str, 10);
    mpz_init(base);
    
    mpz_mul(base, p1, p2);
    mpz_mul(base, base, p3);
    mpz_mul_ui(base, base, 2);
    
    // --- SIEVE INITIALIZATION ---
    long long max_primes = (long long)((double)max_sieve / log(max_sieve) * 1.3); // Safe upper bound via Prime Number Theorem
    long long *sieve_primes = malloc((size_t)max_primes * sizeof(long long));
    long long num_sieve_primes = 0;
    char *is_prime = calloc((size_t)max_sieve + 1, 1);
    for (long long i=2; i<=max_sieve; i++) is_prime[i] = 1;
    for (long long p = 2; p * p <= max_sieve; p++) {
        if (is_prime[p]) {
            for (long long i = p * p; i <= max_sieve; i += p) {
                is_prime[i] = 0;
            }
        }
    }
    for (long long p = 2; p <= max_sieve; p++) {
        if (is_prime[p]) {
            sieve_primes[num_sieve_primes++] = p;
        }
    }
    
    // --- RANDOMIZE SEARCH SPACE ---
    srand((unsigned int)time(NULL));
    for (long long i = num_sieve_primes - 1; i > 0; i--) {
        long long j = rand() % (i + 1);
        long long temp = sieve_primes[i];
        sieve_primes[i] = sieve_primes[j];
        sieve_primes[j] = temp;
    }
    
    long long *K_mod = malloc((size_t)num_sieve_primes * sizeof(long long));
    double M_sieve = 1.0;
    for (long long i=0; i<num_sieve_primes; i++) {
        K_mod[i] = mpz_fdiv_ui(base, (unsigned long)sieve_primes[i]);
        M_sieve *= (1.0 - 1.0 / (double)sieve_primes[i]);
    }
    free(is_prime);
    
    int found = 0;
    int witnesses[] = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97};
    int num_w = 25;
    
    double ln_N = mpz_sizeinbase(base, 2) * 0.69314718;
    int expected_P = (int)(ln_N * M_sieve);
    
    int c_count = 0;
    double start = get_time();
    
    double f_times[MEDIAN_WINDOW];
    int f_idx = 0;
    int f_count = 0;
    
    printf("[*] 3-Prime Linear Search: Base size is %d bits!\n", (int)mpz_sizeinbase(base, 2));
    printf("[*] Built Sieve of Eratosthenes up to %lld (%lld primes).\n", max_sieve, num_sieve_primes);
    printf("[*] Expected Fermat tests to find prime (P): ~%d\n", expected_P);
    printf("[*] Starting fast parallel linear search (C core)...\n\n");
    
    #pragma omp parallel for schedule(dynamic, 1) shared(found, c_count, f_times, f_idx, f_count)
    for (long long i = 0; i < num_sieve_primes; i++) {
        if (found) continue;
        
        long long q = sieve_primes[i];
        int tid = omp_get_thread_num();
        
        // --- FAST C SIEVE ---
        int sieve_failed = 0;
        for (long long s = 0; s < num_sieve_primes; s++) {
            long long p = sieve_primes[s];
            long long m = K_mod[s];
            m = (m * (q % p)) % p;
            if ((m + 1) % p == 0) {
                sieve_failed = 1;
                break;
            }
        }
        if (sieve_failed) continue; 
        
        #pragma omp critical
        {
            c_count++;
            int elapsed = (int)(get_time() - start);
            int e_sec = 0, f_sec = 0;
            char e_sign = '+';
            
            if (f_count > 0) {
                double temp[MEDIAN_WINDOW];
                for (int x=0; x<f_count; x++) temp[x] = f_times[x];
                for (int x=0; x<f_count-1; x++) {
                    for (int y=0; y<f_count-x-1; y++) {
                        if (temp[y] > temp[y+1]) {
                            double t = temp[y]; temp[y] = temp[y+1]; temp[y+1] = t;
                        }
                    }
                }
                f_sec = (int)temp[f_count / 2];
            }
            
            if (c_count > 0) {
                long long diff = (expected_P >= c_count) ? (expected_P - c_count) : (c_count - expected_P);
                e_sign = (expected_P >= c_count) ? '+' : '-';
                if (f_sec > 0) {
                    e_sec = (int)((diff * f_sec) / omp_get_num_threads());
                }
            }
            
            printf("[T%02d | %02d:%02d:%02d | E%c %02d:%02d:%02d | F %02d:%02d] [C %5d | P %5d] [Q %8lld]\n", 
                   tid, 
                   elapsed/3600, (elapsed%3600)/60, elapsed%60, 
                   e_sign, e_sec/3600, (e_sec%3600)/60, e_sec%60,
                   f_sec/60, f_sec%60,
                   c_count, expected_P, q);
            fflush(stdout);
        }
        
        mpz_t cand, cand_m1, res, w, e_val;
        mpz_init(cand);
        mpz_init(cand_m1);
        mpz_init(res);
        mpz_init(w);
        mpz_init(e_val);
        
        mpz_mul_ui(cand_m1, base, (unsigned long)q);
        mpz_add_ui(cand, cand_m1, 1);
        
        for (int wi = 0; wi < num_w; wi++) {
            if (found) break;
            mpz_set_ui(w, witnesses[wi]);
            
            double f_start = get_time();
            mpz_powm(res, w, cand_m1, cand);
            double f_dur = get_time() - f_start;
            
            #pragma omp critical
            {
                f_times[f_idx] = f_dur;
                f_idx = (f_idx + 1) % MEDIAN_WINDOW;
                if (f_count < MEDIAN_WINDOW) f_count++;
            }
            
            if (mpz_cmp_ui(res, 1) != 0) {
                break; 
            }
            
            #pragma omp critical
            {
                printf("[T%02d]      [PASS] Fermat condition met! Checking Pratt factors...\n", tid);
                printf("[T%02d]   -> Checking factor 2\n", tid);
                fflush(stdout);
            }
            
            mpz_divexact_ui(e_val, cand_m1, 2);
            mpz_powm(res, w, e_val, cand);
            if (mpz_cmp_ui(res, 1) == 0) continue;
            
            #pragma omp critical
            {
                printf("[T%02d]   -> Checking factor %lld (q)\n", tid, q);
                fflush(stdout);
            }
            mpz_divexact_ui(e_val, cand_m1, (unsigned long)q);
            mpz_powm(res, w, e_val, cand);
            if (mpz_cmp_ui(res, 1) == 0) continue;
            
            #pragma omp critical
            {
                printf("[T%02d]   -> Checking factor P1\n", tid);
                fflush(stdout);
            }
            mpz_divexact(e_val, cand_m1, p1);
            mpz_powm(res, w, e_val, cand);
            if (mpz_cmp_ui(res, 1) == 0) continue;
            
            #pragma omp critical
            {
                printf("[T%02d]   -> Checking factor P2\n", tid);
                fflush(stdout);
            }
            mpz_divexact(e_val, cand_m1, p2);
            mpz_powm(res, w, e_val, cand);
            if (mpz_cmp_ui(res, 1) == 0) continue;
            
            #pragma omp critical
            {
                printf("[T%02d]   -> Checking factor P3\n", tid);
                fflush(stdout);
            }
            mpz_divexact(e_val, cand_m1, p3);
            mpz_powm(res, w, e_val, cand);
            if (mpz_cmp_ui(res, 1) == 0) continue;
            
            #pragma omp critical
            {
                if (!found) {
                    found = 1;
                    printf("\n*** Found valid prime! q = %lld, W = %d ***\n", q, witnesses[wi]);
                    printf("V 1\nP ");
                    mpz_out_str(stdout, 10, cand);
                    printf("\nW %d\n", witnesses[wi]);
                    
                    // Output raw factors for python to format perfectly
                    printf("F 2\n");
                    printf("F %lld\n", q);
                    printf("F "); mpz_out_str(stdout, 10, p1); printf("\n");
                    printf("F "); mpz_out_str(stdout, 10, p2); printf("\n");
                    printf("F "); mpz_out_str(stdout, 10, p3); printf("\n");
                }
            }
            break;
        }
        
        mpz_clear(cand); mpz_clear(cand_m1);
        mpz_clear(res); mpz_clear(w); mpz_clear(e_val);
    }
    
    return found ? 0 : 1;
}
