#ifndef PULSE_SYSTEM_H
#define PULSE_SYSTEM_H
#include <stdint.h>
typedef struct { int32_t pid; int32_t parent; uint64_t cpu_ns; uint64_t resident; char name[256]; char path[1024]; } PulseProcess;
typedef struct { double device; double renderer; double tiler; uint64_t allocated_memory; uint64_t in_use_memory; int32_t core_count; } PulseGPUStats;
typedef struct { int32_t pid; uint64_t gpu_ns; char name[256]; } PulseGPUProcess;
int pulse_processes(PulseProcess *output, int capacity);
int pulse_gpu_stats(PulseGPUStats *stats, PulseGPUProcess *processes, int capacity);
double pulse_temperature(void);
int32_t pulse_prevent_display_sleep(uint32_t *assertion_id);
int32_t pulse_allow_display_sleep(uint32_t assertion_id);
#endif
