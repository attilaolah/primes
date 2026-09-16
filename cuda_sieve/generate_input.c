#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(const char *message) {
    fprintf(stderr, "generate_input: %s\n", message);
    exit(EXIT_FAILURE);
}

static uint64_t parse_u64(const char *value, const char *name) {
    char *end;
    errno = 0;
    uint64_t result = strtoull(value, &end, 10);
    if (errno || *value == '\0' || *end != '\0') {
        fprintf(stderr, "generate_input: invalid %s: %s\n", name, value);
        exit(EXIT_FAILURE);
    }
    return result;
}

static void append_prime(uint64_t **primes, size_t *count, size_t *capacity, uint64_t prime) {
    if (*count == *capacity) {
        *capacity = *capacity ? *capacity * 2 : 1024;
        uint64_t *new_primes = realloc(*primes, *capacity * sizeof(**primes));
        if (!new_primes) die("out of memory while collecting primes");
        *primes = new_primes;
    }
    (*primes)[(*count)++] = prime;
}

static uint64_t integer_sqrt(uint64_t value) {
    uint64_t root = 0;
    for (uint64_t bit = UINT64_C(1) << 31; bit; bit >>= 1) {
        uint64_t candidate = root | bit;
        if (candidate <= value / candidate) root = candidate;
    }
    return root;
}

int main(int argc, char **argv) {
    if (argc < 6) {
        die("usage: generate_input NUM_LIMBS N Q_START SIEVE_LIMIT LIMB... | @LIMB_FILE");
    }

    uint64_t num_limbs_64 = parse_u64(argv[1], "NUM_LIMBS");
    uint64_t n_64 = parse_u64(argv[2], "N");
    uint64_t q_start = parse_u64(argv[3], "Q_START");
    uint64_t sieve_limit = parse_u64(argv[4], "SIEVE_LIMIT");
    if (num_limbs_64 > UINT32_MAX || n_64 > UINT32_MAX || sieve_limit < 2) {
        die("NUM_LIMBS and N must fit in uint32_t, and SIEVE_LIMIT must be at least 2");
    }
    uint32_t num_limbs = (uint32_t)num_limbs_64;
    uint32_t n = (uint32_t)n_64;

    uint32_t *limbs = malloc((size_t)num_limbs * sizeof(*limbs));
    if (!limbs) die("out of memory while reading limbs");
    if (argv[5][0] == '@') {
        FILE *limb_file = fopen(argv[5] + 1, "r");
        if (!limb_file) die("failed to open limb file");
        for (uint32_t i = 0; i < num_limbs; ++i) {
            if (fscanf(limb_file, "%" SCNu32, &limbs[i]) != 1) die("failed to read limb file");
        }
        fclose(limb_file);
    } else {
        if (argc != 5 + (int)num_limbs) die("wrong number of limbs");
        for (uint32_t i = 0; i < num_limbs; ++i) {
            uint64_t limb = parse_u64(argv[5 + i], "limb");
            if (limb > UINT32_MAX) die("limb must fit in uint32_t");
            limbs[i] = (uint32_t)limb;
        }
    }

    uint64_t root = integer_sqrt(sieve_limit);
    uint8_t *base_is_composite = calloc((size_t)root + 1, 1);
    if (!base_is_composite) die("out of memory while creating base sieve");
    uint64_t *base_primes = NULL;
    size_t base_count = 0, base_capacity = 0;
    for (uint64_t candidate = 2; candidate <= root; ++candidate) {
        if (!base_is_composite[candidate]) {
            append_prime(&base_primes, &base_count, &base_capacity, candidate);
            if (candidate <= root / candidate) {
                for (uint64_t multiple = candidate * candidate; multiple <= root; multiple += candidate) {
                    base_is_composite[multiple] = 1;
                }
            }
        }
    }
    free(base_is_composite);

    uint64_t *primes = NULL;
    size_t prime_count = 0, prime_capacity = 0;
    const uint64_t segment_size = 1 << 20;
    uint8_t *is_composite = malloc(segment_size);
    if (!is_composite) die("out of memory while creating segmented sieve");
    for (uint64_t low = 2; low <= sieve_limit;) {
        uint64_t high = low + segment_size - 1;
        if (high < low || high > sieve_limit) high = sieve_limit;
        size_t length = (size_t)(high - low + 1);
        memset(is_composite, 0, length);
        for (size_t i = 0; i < base_count; ++i) {
            uint64_t prime = base_primes[i];
            uint64_t first = prime * prime;
            if (first < low) first = ((low + prime - 1) / prime) * prime;
            for (uint64_t multiple = first; multiple <= high; multiple += prime) is_composite[multiple - low] = 1;
        }
        for (uint64_t candidate = low; candidate <= high; ++candidate) {
            if (!is_composite[candidate - low]) append_prime(&primes, &prime_count, &prime_capacity, candidate);
        }
        if (high == sieve_limit) break;
        low = high + 1;
    }
    free(base_primes);
    free(is_composite);

    if (prime_count > UINT32_MAX) die("too many primes for sieve input format");
    FILE *out = fopen("sieve_input.bin", "wb");
    if (!out) die("failed to open sieve_input.bin");
    uint32_t num_primes = (uint32_t)prime_count;
    if (fwrite(&num_limbs, sizeof(num_limbs), 1, out) != 1 ||
        fwrite(&num_primes, sizeof(num_primes), 1, out) != 1 ||
        fwrite(&n, sizeof(n), 1, out) != 1 ||
        fwrite(&q_start, sizeof(q_start), 1, out) != 1 ||
        fwrite(limbs, sizeof(*limbs), num_limbs, out) != num_limbs ||
        fwrite(primes, sizeof(*primes), num_primes, out) != num_primes) {
        die("failed to write sieve_input.bin");
    }
    fclose(out);
    free(limbs);
    free(primes);
    return 0;
}
