// Bounded CPU load: spin <threads> <seconds>. Exits on its own; never exceeds the given duration.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double limit;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void *burn(void *arg) { volatile unsigned long x = 0; double end = limit; while (now() < end) for (int i = 0; i < 100000; i++) x += i; return NULL; }
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1; double s = argc > 2 ? atof(argv[2]) : 10;
    if (n < 1 || n > 64 || s <= 0 || s > 30) { fprintf(stderr, "usage: spin <1-64 threads> <0-30 s>\n"); return 2; }
    limit = now() + s; pthread_t t[64];
    for (int i = 0; i < n; i++) pthread_create(&t[i], NULL, burn, NULL);
    for (int i = 0; i < n; i++) pthread_join(t[i], NULL);
    return 0;
}
