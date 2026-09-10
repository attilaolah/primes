#include <stdio.h>
#include <gmp.h>
#include <stdlib.h>
#include <omp.h>
#include <sys/time.h>
#include <time.h>
#include <math.h>
#include <errno.h>
#include <limits.h>
#include <string.h>

#define MEDIAN_WINDOW 101

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

static int test_plan_candidate(unsigned long q, unsigned long index, mpz_t base, mpz_t p1, mpz_t p2, mpz_t p3) {
    int witnesses[] = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97};
    mpz_t candidate, candidate_m1, result, witness_value, exponent, q_value;
    mpz_inits(candidate, candidate_m1, result, witness_value, exponent, q_value, NULL);
    mpz_set_ui(q_value, q);
    printf("TEST index=%lu q=%lu\n", index, q);
    fflush(stdout);
    if (mpz_probab_prime_p(q_value, 25) == 0) goto done;
    mpz_mul_ui(candidate_m1, base, q);
    mpz_add_ui(candidate, candidate_m1, 1);
    for (size_t wi = 0; wi < sizeof(witnesses) / sizeof(witnesses[0]); wi++) {
        mpz_set_ui(witness_value, witnesses[wi]);
        mpz_powm(result, witness_value, candidate_m1, candidate);
        if (mpz_cmp_ui(result, 1) != 0) continue;
        mpz_divexact_ui(exponent, candidate_m1, 2);
        mpz_powm(result, witness_value, exponent, candidate);
        if (mpz_cmp_ui(result, 1) == 0) continue;
        mpz_divexact_ui(exponent, candidate_m1, q);
        mpz_powm(result, witness_value, exponent, candidate);
        if (mpz_cmp_ui(result, 1) == 0) continue;
        mpz_divexact(exponent, candidate_m1, p1);
        mpz_powm(result, witness_value, exponent, candidate);
        if (mpz_cmp_ui(result, 1) == 0) continue;
        mpz_divexact(exponent, candidate_m1, p2);
        mpz_powm(result, witness_value, exponent, candidate);
        if (mpz_cmp_ui(result, 1) == 0) continue;
        mpz_divexact(exponent, candidate_m1, p3);
        mpz_powm(result, witness_value, exponent, candidate);
        if (mpz_cmp_ui(result, 1) == 0) continue;
        printf("\n*** Found valid prime! q = %lu, W = %d ***\n", q, witnesses[wi]);
        printf("V 1\nP "); mpz_out_str(stdout, 10, candidate); printf("\nW %d\n", witnesses[wi]);
        printf("F 2\nF %lu\nF ", q); mpz_out_str(stdout, 10, p1); printf("\nF ");
        mpz_out_str(stdout, 10, p2); printf("\nF "); mpz_out_str(stdout, 10, p3); printf("\n");
        break;
    }
done:
    mpz_clears(candidate, candidate_m1, result, witness_value, exponent, q_value, NULL);
    return 0;
}

static int run_plan(const char *path, mpz_t base, mpz_t p1, mpz_t p2, mpz_t p3) {
    FILE *plan = fopen(path, "r");
    char line[128];
    unsigned long index = 0;
    if (!plan) return 1;
    while (fgets(line, sizeof(line), plan)) {
        char *end;
        unsigned long q;
        size_t length = strlen(line);
        if (length == sizeof(line) - 1 && line[length - 1] != '\n') { fclose(plan); return 1; }
        if (length == 0 || line[length - 1] != '\n') { fclose(plan); return 1; }
        line[length - 1] = '\0';
        if (line[0] == '\0' || line[0] == '-' || (line[0] == '0' && line[1] != '\0')) { fclose(plan); return 1; }
        for (char *value = line; *value; value++) if (*value < '0' || *value > '9') { fclose(plan); return 1; }
        errno = 0;
        q = strtoul(line, &end, 10);
        if (errno == ERANGE || *end != '\0' || q < 2) { fclose(plan); return 1; }
        test_plan_candidate(q, index++, base, p1, p2, p3);
    }
    if (ferror(plan)) { fclose(plan); return 1; }
    fclose(plan);
    printf("DONE\n");
    fflush(stdout);
    return 0;
}

static int read_plan_bases(const char *path, mpz_t p1, mpz_t p2, mpz_t p3) {
    FILE *bases = fopen(path, "r");
    char p1_str[50000], p2_str[50000], p3_str[50000], extra[2];
    if (!bases) return 1;
    if (fscanf(bases, "%49999s%49999s%49999s", p1_str, p2_str, p3_str) != 3 || fscanf(bases, "%1s", extra) == 1) {
        fclose(bases);
        return 1;
    }
    fclose(bases);
    if (mpz_set_str(p1, p1_str, 10) != 0 || mpz_set_str(p2, p2_str, 10) != 0 || mpz_set_str(p3, p3_str, 10) != 0 ||
        mpz_cmp_ui(p1, 2) < 0 || mpz_cmp_ui(p2, 2) < 0 || mpz_cmp_ui(p3, 2) < 0 ||
        mpz_probab_prime_p(p1, 25) == 0 || mpz_probab_prime_p(p2, 25) == 0 || mpz_probab_prime_p(p3, 25) == 0 ||
        mpz_cmp(p1, p2) == 0 || mpz_cmp(p1, p3) == 0 || mpz_cmp(p2, p3) == 0) return 1;
    return 0;
}

int main(int argc, char **argv) {
    const char *plan_path = NULL;
    const char *bases_path = NULL;
    if (argc == 5 && strcmp(argv[1], "--plan") == 0 && strcmp(argv[3], "--bases") == 0) {
        plan_path = argv[2];
        bases_path = argv[4];
    }
    else if (argc != 1) return 1;
    char p1_str[50000], p2_str[50000], p3_str[50000];
    long long max_sieve = 5000000000LL;
    mpz_t p1, p2, p3, base;
    mpz_inits(p1, p2, p3, base, NULL);
    if (plan_path) {
        if (read_plan_bases(bases_path, p1, p2, p3)) {
            mpz_clears(p1, p2, p3, base, NULL);
            return 1;
        }
    } else {
        FILE *f = fopen("search_input.txt", "r");
        if (!f) { mpz_clears(p1, p2, p3, base, NULL); return 1; }
        if (fscanf(f, "%49999s", p1_str) != 1 || fscanf(f, "%49999s", p2_str) != 1 || fscanf(f, "%49999s", p3_str) != 1) {
            fclose(f); mpz_clears(p1, p2, p3, base, NULL); return 1;
        }
        if (fscanf(f, "%lld", &max_sieve) != 1) max_sieve = 5000000000LL;
        fclose(f);
        if (mpz_set_str(p1, p1_str, 10) != 0 || mpz_set_str(p2, p2_str, 10) != 0 || mpz_set_str(p3, p3_str, 10) != 0) {
            mpz_clears(p1, p2, p3, base, NULL); return 1;
        }
    }
    
    mpz_mul(base, p1, p2);
    mpz_mul(base, base, p3);
    mpz_mul_ui(base, base, 2);
    if (plan_path) {
        int status = run_plan(plan_path, base, p1, p2, p3);
        mpz_clears(p1, p2, p3, base, NULL);
        return status;
    }
    
    // --- SIEVE INITIALIZATION ---
    printf("[*] Allocating %lld bytes and marking primes (this takes ~10 seconds)...\n", max_sieve);
    fflush(stdout);
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
    long long extract_step = max_sieve / 1000;
    if (extract_step == 0) extract_step = 1;
    for (long long p = 2; p <= max_sieve; p++) {
        if (is_prime[p]) {
            sieve_primes[num_sieve_primes++] = p;
        }
        if (p % extract_step == 0 && p != max_sieve) {
            printf("\r[*] Extracting primes: %4.1f%% complete...", (double)p * 100.0 / max_sieve);
            fflush(stdout);
        }
    }
    printf("\r[*] Extracting primes: 100.0%% complete...");
    fflush(stdout);
    printf("\n");
    fflush(stdout);
    
    // --- RANDOMIZE SEARCH SPACE ---
    srand((unsigned int)time(NULL));
    for (long long i = num_sieve_primes - 1; i > 0; i--) {
        long long j = rand() % (i + 1);
        long long temp = sieve_primes[i];
        sieve_primes[i] = sieve_primes[j];
        sieve_primes[j] = temp;
    }
    
    printf("[*] Sieve complete! Found %lld primes.\n", num_sieve_primes);
    printf("[*] Precomputing %lld high-precision modulos (this takes a few minutes)...\n", num_sieve_primes);
    fflush(stdout);
    
    long long *K_mod = malloc((size_t)num_sieve_primes * sizeof(long long));
    double M_sieve = 1.0;
    
    // Parallelize modulo precomputation to slice initialization time by 10x-20x
    long long report_step = num_sieve_primes / 1000;
    if (report_step == 0) report_step = 1;
    
    int done_count = 0;
    #pragma omp parallel for schedule(static) reduction(*:M_sieve)
    for (long long i = 0; i < num_sieve_primes; i++) {
        K_mod[i] = mpz_fdiv_ui(base, (unsigned long)sieve_primes[i]);
        M_sieve *= (1.0 - 1.0 / (double)sieve_primes[i]);
        
        #pragma omp atomic
        done_count++;
        
        if (omp_get_thread_num() == 0 && done_count % report_step == 0) {
            printf("\r[*] Modulo precomputation (Parallel): %4.1f%% complete...", (double)done_count * 100.0 / num_sieve_primes);
            fflush(stdout);
        }
    }
    printf("\r[*] Modulo precomputation (Parallel): 100.0%% complete...\n");
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

            double prime_probability;
            if (c_count <= 0 || expected_P <= 0) {
                prime_probability = 0.0;
            } else if (expected_P == 1) {
                prime_probability = 1.0;
            } else {
                prime_probability = -expm1(c_count * log1p(-1.0 / expected_P));
                if (prime_probability < 0.0) prime_probability = 0.0;
                if (prime_probability > 1.0) prime_probability = 1.0;
            }
            
            printf("[T%02d | %02d:%02d:%02d | E%c %02d:%02d:%02d | F %02d:%02d] [C %5d | P %5d | %.2f%%] [Q %8lld]\n", 
                    tid, 
                    elapsed/3600, (elapsed%3600)/60, elapsed%60, 
                    e_sign, e_sec/3600, (e_sec%3600)/60, e_sec%60,
                    f_sec/60, f_sec%60,
                    c_count, expected_P, prime_probability * 100.0, q);
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
