#include <stdint.h>
#include <stddef.h>
#include <gmp.h>

/*
 * Clear the one q residue class for every divisor whose corresponding factor
 * residue is non-zero.  Parse the decimal factor once, then reduce it for each
 * divisor here so Python does not perform a big-integer division per prime.
 */
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

/*
 * Stable ctypes ABI: returns 0, 1 for an invalid divisor, or 2 when factor
 * cannot be parsed as a base-10 GMP integer.
 */
int candidate_filter(uint8_t *eligible, uint64_t limit,
                      const uint64_t *divisors, size_t count,
                      const char *factor_decimal) {
    mpz_t factor;
    mpz_init(factor);
    if (mpz_set_str(factor, factor_decimal, 10) != 0) {
        mpz_clear(factor);
        return 2;
    }
    for (size_t index = 0; index < count; ++index) {
        uint64_t divisor = divisors[index];
        if (divisor < 2) {
            mpz_clear(factor);
            return 1;
        }
        uint64_t factor_mod = mpz_fdiv_ui(factor, divisor);
        if (factor_mod == 0) continue;
        uint64_t inverse = inverse_mod(factor_mod, divisor);
        uint64_t residue = inverse == 0 ? 0 : divisor - inverse;
        if (residue > limit) continue;
        for (uint64_t q = residue;;) {
            eligible[q] = 0;
            if (limit - q < divisor) break;
            q += divisor;
        }
    }
    mpz_clear(factor);
    return 0;
}
