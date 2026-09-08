#include "PulseSystem.h"
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
int pulse_processes(PulseProcess *out, int capacity) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return 0;
    int *pids = calloc(1, bytes + 4096);
    if (!pids) return 0;
    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes + 4096) / sizeof(int), n = 0;
    for (int i = 0; i < count && n < capacity; i++) {
        struct proc_taskinfo task;
        if (pids[i] <= 0 || proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) continue;
        out[n].pid = pids[i]; out[n].cpu_ns = (uint64_t)(((__uint128_t)task.pti_total_user + task.pti_total_system) * timebase.numer / timebase.denom); out[n].resident = task.pti_resident_size;
        memset(out[n].name, 0, 256); proc_name(pids[i], out[n].name, 255); n++;
        PulseProcess *entry = &out[n - 1];
        memset(entry->path, 0, sizeof(entry->path));
        proc_pidpath(pids[i], entry->path, sizeof(entry->path));
        struct proc_bsdinfo bsd = {0};
        entry->parent = proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) == sizeof(bsd) ? bsd.pbi_ppid : 0;
    }
    free(pids); return n;
}
// AppleSMC read-only user-client protocol. No fan or power settings are changed.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct { uint32_t key; Version version; Limits limits; KeyInfo info; uint8_t result, status, command; uint32_t value; uint8_t bytes[32]; } SMCData;
_Static_assert(sizeof(SMCData) == 80, "Unexpected SMC ABI");
static uint32_t fourcc(const char *s) { return (uint32_t)s[0]<<24 | (uint32_t)s[1]<<16 | (uint32_t)s[2]<<8 | (uint32_t)s[3]; }
static double read_sensor(io_connect_t connection, const char *key) {
    SMCData in = {0}, out = {0}; size_t size = sizeof(out);
    in.key = fourcc(key); in.command = 9;
    if (IOConnectCallStructMethod(connection, 2, &in, sizeof(in), &out, &size) != KERN_SUCCESS || out.result) return -1;
    uint32_t type = out.info.type; in.info.size = out.info.size; in.command = 5; size = sizeof(out);
    if (in.info.size > 32 || IOConnectCallStructMethod(connection, 2, &in, sizeof(in), &out, &size) != KERN_SUCCESS || out.result) return -1;
    double value = -1;
    if (type == fourcc("sp78") && in.info.size == 2) value = (int16_t)((out.bytes[0]<<8) | out.bytes[1]) / 256.0;
    if (type == fourcc("flt ") && in.info.size == 4) { float f; memcpy(&f, out.bytes, 4); value = f; }
    return value > 0 && value < 130 ? value : -1;
}
double pulse_temperature(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    io_connect_t connection = 0; kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection); IOObjectRelease(service);
    if (result != KERN_SUCCESS) return -1;
    const char *keys[] = {"TC0P", "TC0D", "TC0E", "TC0F", "TCAD", "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0O", "Tp0R", "Tp0U", "Tp0X"};
    double total = 0; int count = 0;
    for (unsigned i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) { double t = read_sensor(connection, keys[i]); if (t > 0) { total += t; count++; } }
    IOServiceClose(connection); return count ? total/count : -1;
}
