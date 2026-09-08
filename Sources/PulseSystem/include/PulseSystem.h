#ifndef PULSE_SYSTEM_H
#define PULSE_SYSTEM_H
#include <stdint.h>
typedef struct { int32_t pid; int32_t parent; uint64_t cpu_ns; uint64_t resident; char name[256]; char path[1024]; } PulseProcess;
int pulse_processes(PulseProcess *output, int capacity);
double pulse_temperature(void);
#endif
