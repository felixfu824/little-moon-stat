// Bounded memory load: memhog <MiB 1-4096> <seconds 1-30>. Fills every byte with pseudo-random data
// (incompressible), reads it back into a printed checksum (so the compiler cannot drop the stores), holds, exits.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
int main(int argc, char **argv) {
    long mb = argc > 1 ? atol(argv[1]) : 1024; int s = argc > 2 ? atoi(argv[2]) : 10;
    if (mb < 1 || mb > 4096 || s < 1 || s > 30) { fprintf(stderr, "usage: memhog <1-4096 MiB> <1-30 s>\n"); return 2; }
    size_t n = ((size_t)mb << 20) / sizeof(uint64_t); volatile uint64_t *p = malloc(n * sizeof(uint64_t)); if (!p) return 1;
    uint64_t x = 88172645463325252ULL, sum = 0;
    for (size_t i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; p[i] = x; }
    for (size_t i = 0; i < n; i += 512) sum += p[i];
    fprintf(stderr, "memhog %ld MiB resident, checksum %llu\n", mb, (unsigned long long)sum);
    sleep(s); free((void *)p); return 0;
}
