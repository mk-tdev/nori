#include "PulseSystem.h"
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

static uint64_t dictionary_number(CFDictionaryRef dictionary, CFStringRef key, uint64_t fallback) {
    if (!dictionary) return fallback;
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return fallback;
    int64_t number = 0;
    return CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number) && number >= 0 ? (uint64_t)number : fallback;
}

static io_service_t gpu_service(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"));
    if (!service) service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    return service;
}

int pulse_gpu_stats(PulseGPUStats *stats, PulseGPUProcess *processes, int capacity) {
    if (!stats) return 0;
    memset(stats, 0, sizeof(*stats));
    stats->device = stats->renderer = stats->tiler = -1;
    io_service_t service = gpu_service();
    if (!service) return 0;

    CFTypeRef performance = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (performance && CFGetTypeID(performance) == CFDictionaryGetTypeID()) {
        CFDictionaryRef values = (CFDictionaryRef)performance;
        uint64_t device = dictionary_number(values, CFSTR("Device Utilization %"), UINT64_MAX);
        uint64_t renderer = dictionary_number(values, CFSTR("Renderer Utilization %"), UINT64_MAX);
        uint64_t tiler = dictionary_number(values, CFSTR("Tiler Utilization %"), UINT64_MAX);
        if (device != UINT64_MAX) stats->device = (double)device;
        if (renderer != UINT64_MAX) stats->renderer = (double)renderer;
        if (tiler != UINT64_MAX) stats->tiler = (double)tiler;
        stats->allocated_memory = dictionary_number(values, CFSTR("Alloc system memory"), 0);
        stats->in_use_memory = dictionary_number(values, CFSTR("In use system memory"), 0);
    }
    if (performance) CFRelease(performance);

    CFTypeRef cores = IORegistryEntryCreateCFProperty(service, CFSTR("gpu-core-count"), kCFAllocatorDefault, 0);
    if (cores && CFGetTypeID(cores) == CFNumberGetTypeID()) {
        int32_t count = 0;
        if (CFNumberGetValue((CFNumberRef)cores, kCFNumberSInt32Type, &count)) stats->core_count = count;
    }
    if (cores) CFRelease(cores);

    int output_count = 0;
    io_iterator_t iterator = 0;
    if (processes && capacity > 0 && IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &iterator) == KERN_SUCCESS) {
        io_registry_entry_t entry;
        while (output_count < capacity && (entry = IOIteratorNext(iterator))) {
            CFTypeRef creator = IORegistryEntryCreateCFProperty(entry, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
            CFTypeRef usage = IORegistryEntryCreateCFProperty(entry, CFSTR("AppUsage"), kCFAllocatorDefault, 0);
            if (creator && usage && CFGetTypeID(creator) == CFStringGetTypeID() && CFGetTypeID(usage) == CFArrayGetTypeID()) {
                char text[512] = {0}; int pid = 0;
                if (CFStringGetCString((CFStringRef)creator, text, sizeof(text), kCFStringEncodingUTF8) && sscanf(text, "pid %d", &pid) == 1 && pid > 0) {
                    uint64_t total = 0;
                    CFArrayRef items = (CFArrayRef)usage;
                    for (CFIndex index = 0; index < CFArrayGetCount(items); index++) {
                        CFTypeRef item = CFArrayGetValueAtIndex(items, index);
                        if (item && CFGetTypeID(item) == CFDictionaryGetTypeID()) total += dictionary_number((CFDictionaryRef)item, CFSTR("accumulatedGPUTime"), 0);
                    }
                    processes[output_count].pid = pid;
                    processes[output_count].gpu_ns = total;
                    memset(processes[output_count].name, 0, sizeof(processes[output_count].name));
                    const char *name = strchr(text, ',');
                    if (name) { name++; while (*name == ' ') name++; }
                    else name = "GPU process";
                    strncpy(processes[output_count].name, name, sizeof(processes[output_count].name) - 1);
                    output_count++;
                }
            }
            if (creator) CFRelease(creator);
            if (usage) CFRelease(usage);
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }
    IOObjectRelease(service);
    return output_count;
}

int32_t pulse_prevent_display_sleep(uint32_t *assertion_id) {
    if (!assertion_id) return kIOReturnBadArgument;
    return IOPMAssertionCreateWithName(
        kIOPMAssertPreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("Nori Keep Awake"),
        assertion_id
    );
}

int32_t pulse_allow_display_sleep(uint32_t assertion_id) {
    return IOPMAssertionRelease(assertion_id);
}

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
