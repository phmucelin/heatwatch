#include "sensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <notify.h>
#include <string.h>

// Private IOKit HID API. Apple Silicon exposes its die/SSD/battery thermal
// sensors here, readable by any user process.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kHIDPageAppleVendor 0xff00
#define kHIDUsageAppleVendorTemperatureSensor 5

static IOHIDEventSystemClientRef shared_client(void) {
    static IOHIDEventSystemClientRef client = NULL;
    if (client) return client;

    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;

    int page = kHIDPageAppleVendor, usage = kHIDUsageAppleVendorTemperatureSensor;
    CFNumberRef page_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usage_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {page_num, usage_num};
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(page_num);
    CFRelease(usage_num);
    return client;
}

int hw_read_temperatures(hw_temp_t *out, int max) {
    IOHIDEventSystemClientRef client = shared_client();
    if (!client) return 0;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;

    int n = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && n < max; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;

        out[n].value = IOHIDEventGetFloatValue(event, kIOHIDEventTypeTemperature << 16);
        out[n].name[0] = '\0';
        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (name) {
            if (CFGetTypeID(name) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)name, out[n].name, sizeof out[n].name, kCFStringEncodingUTF8);
            }
            CFRelease(name);
        }
        CFRelease(event);
        n++;
    }
    CFRelease(services);
    return n;
}

// MARK: - SMC
//
// The HID sensors above only cover the PMU, SSD and battery on M4, so core
// temperatures come from the SMC, through the same user client that Stats,
// iStat Menus and TG Pro use.

typedef struct {
    char major, minor, build, reserved;
    uint16_t release;
} smc_version_t;

typedef struct {
    uint16_t version, length;
    uint32_t cpu_limit, gpu_limit, mem_limit;
} smc_plimit_t;

typedef struct {
    uint32_t size;
    uint32_t type;
    char attributes;
} smc_keyinfo_t;

typedef struct {
    uint32_t key;
    smc_version_t version;
    smc_plimit_t plimit;
    smc_keyinfo_t info;
    char result, status, command;
    uint32_t data32;
    unsigned char bytes[32];
} smc_param_t;

enum { kSMCUserClientMethod = 2, kSMCReadBytes = 5, kSMCKeyAtIndex = 8, kSMCReadKeyInfo = 9 };

#define FOURCC(s) (((uint32_t)(s)[0] << 24) | ((uint32_t)(s)[1] << 16) | ((uint32_t)(s)[2] << 8) | (uint32_t)(s)[3])
#define MAX_SMC_KEYS 256

static io_connect_t smc_conn = 0;
static uint32_t cpu_keys[MAX_SMC_KEYS], gpu_keys[MAX_SMC_KEYS];
static int cpu_key_count = 0, gpu_key_count = 0;
static int smc_state = 0; // 0 untried, 1 ready, -1 unavailable

static int smc_call(smc_param_t *in, smc_param_t *out) {
    size_t out_size = sizeof *out;
    memset(out, 0, sizeof *out);
    kern_return_t kr = IOConnectCallStructMethod(smc_conn, kSMCUserClientMethod, in, sizeof *in, out, &out_size);
    return (kr == KERN_SUCCESS && out->result == 0) ? 0 : -1;
}

static int smc_key_info(uint32_t key, smc_keyinfo_t *info) {
    smc_param_t in = {0}, out;
    in.key = key;
    in.command = kSMCReadKeyInfo;
    if (smc_call(&in, &out)) return -1;
    *info = out.info;
    return 0;
}

static int smc_read_float(uint32_t key, float *value) {
    smc_param_t in = {0}, out;
    in.key = key;
    in.info.size = 4;
    in.command = kSMCReadBytes;
    if (smc_call(&in, &out)) return -1;
    memcpy(value, out.bytes, 4);
    return 0;
}

// Enumerating every SMC key is slow (~2000 calls), so do it once and keep
// only the float temperature keys we care about.
static int smc_setup(void) {
    if (smc_state) return smc_state;
    smc_state = -1;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return smc_state;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &smc_conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return smc_state;

    smc_param_t in = {0}, out;
    in.key = FOURCC("#KEY");
    in.info.size = 4;
    in.command = kSMCReadBytes;
    if (smc_call(&in, &out)) return smc_state;
    uint32_t total = ((uint32_t)out.bytes[0] << 24) | ((uint32_t)out.bytes[1] << 16) | ((uint32_t)out.bytes[2] << 8) | out.bytes[3];

    for (uint32_t i = 0; i < total; i++) {
        memset(&in, 0, sizeof in);
        in.command = kSMCKeyAtIndex;
        in.data32 = i;
        if (smc_call(&in, &out)) continue;
        uint32_t key = out.key;
        char c0 = (char)(key >> 24), c1 = (char)(key >> 16);
        int is_cpu = c0 == 'T' && (c1 == 'p' || c1 == 'e');
        int is_gpu = c0 == 'T' && c1 == 'g';
        if (!is_cpu && !is_gpu) continue;

        smc_keyinfo_t info;
        if (smc_key_info(key, &info) || info.type != FOURCC("flt ") || info.size != 4) continue;
        if (is_cpu && cpu_key_count < MAX_SMC_KEYS) cpu_keys[cpu_key_count++] = key;
        if (is_gpu && gpu_key_count < MAX_SMC_KEYS) gpu_keys[gpu_key_count++] = key;
    }
    smc_state = cpu_key_count > 0 ? 1 : -1;
    return smc_state;
}

static int smc_stats(const uint32_t *keys, int count, double *avg, double *max) {
    double sum = 0, hottest = 0;
    int n = 0;
    for (int i = 0; i < count; i++) {
        float value;
        if (smc_read_float(keys[i], &value)) continue;
        if (value <= 5 || value >= 130) continue; // unused sensors read 0 or garbage
        sum += value;
        if (value > hottest) hottest = value;
        n++;
    }
    if (!n) return -1;
    *avg = sum / n;
    if (max) *max = hottest;
    return 0;
}

int hw_read_chip_temps(hw_chip_temps_t *out) {
    memset(out, 0, sizeof *out);
    if (smc_setup() != 1) return -1;
    if (smc_stats(cpu_keys, cpu_key_count, &out->cpu_avg, &out->cpu_max)) return -1;
    smc_stats(gpu_keys, gpu_key_count, &out->gpu_avg, NULL);
    return 0;
}

int hw_thermal_pressure(void) {
    static int token = 0;
    static int registered = 0;
    if (!registered) {
        if (notify_register_check("com.apple.system.thermalpressurelevel", &token) != NOTIFY_STATUS_OK) return -1;
        registered = 1;
    }
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return -1;
    return (int)state;
}
