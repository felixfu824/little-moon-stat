// Read-only temperature sensor probe: IOHID temperature services + AppleSMC 'T*' keys.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>

// ---- IOHID (private) ----
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kIOHIDEventTypeTemperature 15

static void probe_hid(void) {
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *v[] = {p, u};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(sys, match);
    CFArrayRef svcs = IOHIDEventSystemClientCopyServices(sys);
    long n = svcs ? CFArrayGetCount(svcs) : 0;
    printf("# HID services: %ld\n", n);
    for (long i = 0; i < n; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        char buf[128] = "?";
        if (name && CFGetTypeID(name) == CFStringGetTypeID()) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, kIOHIDEventTypeTemperature, 0, 0);
        double t = ev ? IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16) : -1;
        printf("HID\t%s\t%.2f\n", buf, t);
        if (ev) CFRelease(ev);
        if (name) CFRelease(name);
    }
}

// ---- AppleSMC ----
typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    char result, status, data8; uint32_t data32; unsigned char bytes[32];
} SMCKeyData;

static io_connect_t conn;
static uint32_t fourcc(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }
static void unfourcc(uint32_t v, char *o) { o[0] = v >> 24; o[1] = v >> 16; o[2] = v >> 8; o[3] = v; o[4] = 0; }
static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t sz = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData), out, &sz);
}
static int smc_info(uint32_t key, SMCKeyInfo *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = key; in.data8 = 9;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result) return -1;
    *info = out.keyInfo; return 0;
}
static int smc_read(uint32_t key, SMCKeyInfo info, unsigned char *bytes) {
    SMCKeyData in = {0}, out = {0};
    in.key = key; in.keyInfo.dataSize = info.dataSize; in.data8 = 5;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result) return -1;
    memcpy(bytes, out.bytes, 32); return 0;
}

static void probe_smc(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) { printf("# SMC open failed\n"); return; }
    SMCKeyInfo info; unsigned char b[32];
    if (smc_info(fourcc("#KEY"), &info) || smc_read(fourcc("#KEY"), info, b)) { printf("# SMC #KEY failed\n"); return; }
    uint32_t count = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
    printf("# SMC keys: %u\n", count);
    for (uint32_t i = 0; i < count; i++) {
        SMCKeyData in = {0}, out = {0};
        in.data8 = 8; in.data32 = i;
        if (smc_call(&in, &out) != kIOReturnSuccess) continue;
        char name[5]; unfourcc(out.key, name);
        if (name[0] != 'T') continue;
        if (smc_info(out.key, &info) || smc_read(out.key, info, b)) continue;
        char type[5]; unfourcc(info.dataType, type);
        if (strcmp(type, "flt ") == 0 && info.dataSize == 4) {
            float f; memcpy(&f, b, 4);
            printf("SMC\t%s\t%.2f\n", name, f);
        }
    }
    IOServiceClose(conn);
}

int main(void) { probe_hid(); probe_smc(); return 0; }
