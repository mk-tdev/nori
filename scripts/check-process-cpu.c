// Regression: CPU time must be nanoseconds on both Apple Silicon and Intel.
#include "PulseSystem.h"
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <assert.h>
#include <stdlib.h>
static uint64_t own_cpu(void) {
    PulseProcess *processes = calloc(8192, sizeof(PulseProcess));
    assert(processes);
    int n = pulse_processes(processes, 8192);
    for (int i = 0; i < n; i++) if (processes[i].pid == getpid()) { uint64_t cpu = processes[i].cpu_ns; free(processes); return cpu; }
    free(processes);
    assert(0 && "Current process missing"); return 0;
}
int main(void) {
    uint64_t before = own_cpu();
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    volatile unsigned long work = 0;
    while (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < 200000000) work++;
    uint64_t after = own_cpu();
    double seconds = (after - before) / 1e9;
    printf("CPU time for 0.2s of work: %.3fs\n", seconds);
    assert(seconds >= 0.18 && seconds < 0.5);
}
