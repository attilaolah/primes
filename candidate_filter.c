#include <gmp.h>
#include <omp.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t inverse_mod(uint64_t value, uint64_t modulus) {
    __int128 old_r = value, r = modulus, old_s = 1, s = 0;
    while (r != 0) {
        uint64_t quotient = (uint64_t)(old_r / r);
        __int128 next_r = old_r - (__int128)quotient * r;
        old_r = r;
        r = next_r;
        __int128 next_s = old_s - (__int128)quotient * s;
        old_s = s;
        s = next_s;
    }
    old_s %= (__int128)modulus;
    if (old_s < 0) old_s += modulus;
    return (uint64_t)old_s;
}

static void report_progress(int interactive, uint64_t *next_report,
                            const size_t *completed, size_t count) {
    uint64_t now = (uint64_t)(omp_get_wtime() * 1000000000.0);
    if (!interactive || now < __atomic_load_n(next_report, __ATOMIC_RELAXED)) return;
#pragma omp critical(candidate_filter_progress)
    {
        now = (uint64_t)(omp_get_wtime() * 1000000000.0);
        if (now >= __atomic_load_n(next_report, __ATOMIC_RELAXED)) {
            fprintf(stderr,
                    "\r[*] Native filtering: %zu/%zu completed divisor-prime work",
                    __atomic_load_n(completed, __ATOMIC_RELAXED), count);
            fflush(stderr);
            __atomic_store_n(next_report, now + 250000000, __ATOMIC_RELAXED);
        }
    }
}

/*
 * Stable ctypes ABI: returns 0, 1 for an invalid divisor, or 2 when factor
 * cannot be parsed as a base-10 GMP integer.
 */
int candidate_filter(uint8_t *eligible, uint64_t limit,
                     const uint64_t *divisors, size_t count,
                     const char *factor_decimal) {
    mpz_t validation_factor;
    mpz_init(validation_factor);
    if (mpz_set_str(validation_factor, factor_decimal, 10) != 0) {
        mpz_clear(validation_factor);
        return 2;
    }
    mpz_clear(validation_factor);
    for (size_t index = 0; index < count; ++index) {
        if (divisors[index] < 2) return 1;
    }

    const int interactive = isatty(fileno(stderr));
    size_t completed = 0;
    uint64_t next_report = (uint64_t)(omp_get_wtime() * 1000000000.0) + 250000000;

#pragma omp parallel
    {
        /* GMP integers are mutable, so every worker owns its parsed factor. */
        mpz_t factor;
        mpz_init(factor);
        (void)mpz_set_str(factor, factor_decimal, 10);

#pragma omp single
        {
            fprintf(stderr, "[*] Native candidate filtering: %d OpenMP workers\n",
                    omp_get_num_threads());
            fflush(stderr);
        }

        /* Small divisors mark far more bytes, so dynamic chunks balance work. */
#pragma omp for schedule(dynamic, 32)
        for (size_t index = 0; index < count; ++index) {
            uint64_t divisor = divisors[index];
            uint64_t factor_mod = mpz_fdiv_ui(factor, divisor);
            if (factor_mod != 0) {
                uint64_t inverse = inverse_mod(factor_mod, divisor);
                uint64_t residue = inverse == 0 ? 0 : divisor - inverse;
                if (residue <= limit) {
                    uint64_t markings = 0;
                    for (uint64_t q = residue;;) {
                        __atomic_store_n(eligible + q, 0, __ATOMIC_RELAXED);
                        if (++markings % 262144 == 0) {
                            report_progress(interactive, &next_report, &completed, count);
                        }
                        if (limit - q < divisor) break;
                        q += divisor;
                    }
                }
            }

            size_t done;
#pragma omp atomic capture
            done = ++completed;
            (void)done;
            report_progress(interactive, &next_report, &completed, count);
        }
        mpz_clear(factor);
    }
    if (interactive) {
        fprintf(stderr, "\r[*] Native filtering: %zu/%zu completed divisor-prime work\n",
                completed, count);
        fflush(stderr);
    }
    return 0;
}

/*
 * Bitmap-driven ABI used by the normal planner.  The caller retains prime;
 * candidates is malloc-owned by this library and must be released with
 * candidate_filter_free.  Returns 0 on success, 2 for an invalid factor, or
 * 3 for allocation failure.
 */
int candidate_filter_from_sieve(const uint8_t *prime, uint64_t limit,
                                const char *factor_decimal,
                                uint64_t **candidates, size_t *candidate_count) {
    *candidates = NULL;
    *candidate_count = 0;
    if (limit == UINT64_MAX || limit > SIZE_MAX - 1) return 3;

    mpz_t validation_factor;
    mpz_init(validation_factor);
    if (mpz_set_str(validation_factor, factor_decimal, 10) != 0) {
        mpz_clear(validation_factor);
        return 2;
    }
    mpz_clear(validation_factor);

    size_t table_size = (size_t)limit + 1;
    uint8_t *eligible = malloc(table_size);
    if (eligible == NULL) return 3;
    memcpy(eligible, prime, table_size);

    const int interactive = isatty(fileno(stderr));
    size_t completed = 0;
    uint64_t next_report = (uint64_t)(omp_get_wtime() * 1000000000.0) + 250000000;

#pragma omp parallel
    {
        mpz_t factor;
        mpz_init(factor);
        (void)mpz_set_str(factor, factor_decimal, 10);

#pragma omp single
        {
            fprintf(stderr, "[*] Native candidate filtering: %d OpenMP workers\n",
                    omp_get_num_threads());
            fflush(stderr);
        }

#pragma omp for schedule(dynamic, 32)
        for (uint64_t divisor = 2; divisor <= limit; ++divisor) {
            if (prime[divisor]) {
                uint64_t factor_mod = mpz_fdiv_ui(factor, divisor);
                if (factor_mod != 0) {
                    uint64_t inverse = inverse_mod(factor_mod, divisor);
                    uint64_t residue = inverse == 0 ? 0 : divisor - inverse;
                    if (residue <= limit) {
                        for (uint64_t q = residue;;) {
                            __atomic_store_n(eligible + q, 0, __ATOMIC_RELAXED);
                            if (limit - q < divisor) break;
                            q += divisor;
                        }
                    }
                }
                size_t done;
#pragma omp atomic capture
                done = ++completed;
                (void)done;
                report_progress(interactive, &next_report, &completed, (size_t)limit);
            }
        }
        mpz_clear(factor);
    }

    if (interactive) {
        fprintf(stderr, "\r[*] Native filtering: %zu completed divisor-prime work\n", completed);
        fflush(stderr);
    }

    size_t count = 0;
    for (uint64_t q = 2; q <= limit; ++q) count += eligible[q] != 0;
    uint64_t *result = calloc(count == 0 ? 1 : count, sizeof(*result));
    if (result == NULL) {
        free(eligible);
        return 3;
    }
    size_t index = 0;
    uint64_t next_collection_report = 20000000;
    bool reported_collection_progress = false;
    for (uint64_t q = 2; q <= limit; ++q) {
        if (eligible[q]) result[index++] = q;
        if (interactive && q >= next_collection_report) {
            fprintf(stderr, "\r[*] Candidate collection: %llu/%llu primes examined",
                    (unsigned long long)q, (unsigned long long)limit);
            fflush(stderr);
            next_collection_report += 20000000;
            reported_collection_progress = true;
        }
    }
    if (reported_collection_progress) {
        fputc('\n', stderr);
        fflush(stderr);
    }
    free(eligible);
    *candidates = result;
    *candidate_count = count;
    return 0;
}

void candidate_filter_free(void *pointer) {
    free(pointer);
}
