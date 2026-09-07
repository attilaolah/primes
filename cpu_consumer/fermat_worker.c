#include <stdio.h>
#include <stdlib.h>
#include <gmp.h>
#include <omp.h>
#include <sys/time.h>

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main() {
    FILE *f = fopen("batch_input.txt", "r");
    if (!f) {
        printf("[-] Could not find batch_input.txt\n");
        return 1;
    }

    char p1_str[50000], p2_str[50000], p3_str[50000];
    if (fscanf(f, "%49999s", p1_str) != 1) return 1;
    if (fscanf(f, "%49999s", p2_str) != 1) return 1;
    if (fscanf(f, "%49999s", p3_str) != 1) return 1;

    mpz_t base, p1, p2, p3;
    mpz_inits(base, p1, p2, p3, NULL);
    mpz_set_str(p1, p1_str, 10);
    mpz_set_str(p2, p2_str, 10);
    mpz_set_str(p3, p3_str, 10);
    
    mpz_mul(base, p1, p2);
    mpz_mul(base, base, p3);
    mpz_mul_ui(base, base, 2);

    int num_qs;
    if (fscanf(f, "%d", &num_qs) != 1) return 1;

    long long *qs = malloc(num_qs * sizeof(long long));
    for (int i = 0; i < num_qs; i++) {
        if (fscanf(f, "%lld", &qs[i]) != 1) {
            printf("[-] Failed to read candidate %d from batch_input.txt\n", i);
            fclose(f);
            return 1;
        }
    }
    fclose(f);

    int found = 0;

    printf("[*] Loaded %d highly-refined GPU survivors. Beginning Fermat tests...\n", num_qs);
    
    #pragma omp parallel for schedule(dynamic, 1) shared(found)
    for (int i = 0; i < num_qs; i++) {
        if (found) continue;

        mpz_t P, E, res, three;
        mpz_inits(P, E, res, three, NULL);
        mpz_set_ui(three, 3);

        // P = base * q + 1
        mpz_mul_ui(P, base, qs[i]);
        mpz_add_ui(P, P, 1);

        // E = P - 1
        mpz_sub_ui(E, P, 1);

        double t0 = get_time();
        // res = 3^E mod P
        mpz_powm(res, three, E, P);
        double t1 = get_time();

        if (mpz_cmp_ui(res, 1) == 0) {
            #pragma omp critical
            {
                found = 1;
                printf("\n======================================================\n");
                printf("[+] PRIME FOUND! Q = %lld\n", qs[i]);
                printf("======================================================\n\n");
                FILE *out = fopen("FOUND_PRIME.txt", "w");
                gmp_fprintf(out, "%Zd\n", P);
                fclose(out);
            }
        } else {
            #pragma omp critical
            {
                printf("[-] Q = %lld failed Fermat test (%.2fs)\n", qs[i], t1 - t0);
            }
        }

        mpz_clears(P, E, res, three, NULL);
    }

    mpz_clears(base, p1, p2, p3, NULL);
    free(qs);
    return found ? 0 : 2;
}
