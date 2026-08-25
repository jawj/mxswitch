//
//  mxswitch.m
//
//  Watches for Logitech MX peripherals leaving this Mac (via Easy-Switch)
//  and pushes the external display over to the other input using DDC/CI.
//
//  Event-driven: no polling. IOHIDManager calls us on device attach/remove.
//
//  Build and install (compiles, bundles, signs, loads the LaunchAgent):
//    ./build.sh 16       # personal Mac, hands monitor to input 16
//    ./build.sh 15       # work Mac, hands monitor to input 15
//
//  Bundle / LaunchAgent identifier: com.mackerron.mxswitch
//
//  Manual build, if not using build.sh:
//    clang -fobjc-arc -O2 -Wall -o mxswitch mxswitch.m \
//        -framework Foundation -framework IOKit \
//        -framework IOBluetooth -framework CoreDisplay
//
//  NOTE: IOAVServiceCreate / IOAVServiceWriteI2C are PRIVATE symbols and live
//  in CoreDisplay.framework, NOT IOKit — the build must link -framework
//  CoreDisplay or these come out as undefined at link time.
//  Verified against m1ddc v1.2.0 (MIT): https://github.com/waydabber/m1ddc
//
//  Apple Silicon only. On Intel, DDC goes via IOFramebufferI2C instead
//  (see ddcctl) and setDisplayInput() below must be rewritten.
//

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#include <unistd.h>

// ---------------------------------------------------------------- config

static const uint32_t kLogitechVendorID = 0x046d;

// Input source to hand the monitor to. Per m1ddc's README the common values
// are DisplayPort 1: 15, DisplayPort 2: 16, HDMI 1: 17, HDMI 2: 18, USB-C: 27.
// Confirm on your own panel with `m1ddc get input` while each input is active.
static uint8_t kTargetInput = 16;

// --- DDC constants, taken from m1ddc v1.2.0 (headers/i2c.h) ---
static const uint32_t kDDCChipAddress  = 0x37;  // 0xB7 for MCDP29xx converters
static const uint32_t kDDCDataAddress  = 0x51;  // 0x50 on some LG panels
static const uint8_t  kVCPInputSource  = 0x60;  // 0xF4 on some LG panels
static const int      kDDCIterations   = 2;     // some displays need more
static const useconds_t kDDCWaitMicros = 10000; // some displays need 50000

// Only devices whose product name contains this are counted.
static NSString *const kProductMatch = @"MX";

// All matching devices must disappear within this window for it to count as
// a deliberate Easy-Switch rather than independent idle drop-offs.
static const NSTimeInterval kDrainWindow = 2.0;

// Ignore the event if there has been no human input for longer than this.
static const NSTimeInterval kIdleLimit = 120.0;

// Refuse to fire twice in quick succession.
static const NSTimeInterval kCooldown = 10.0;

// ------------------------------------------------- private API surface

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t offset,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

extern int IOBluetoothPreferenceGetControllerPowerState(void);

// ---------------------------------------------------------------- state

static NSMutableSet<NSString *> *gAttached;   // product names currently present
static NSDate *gDrainStart;                   // when the current drain began
static NSDate *gLastFire;

// ---------------------------------------------------------------- utils

static void mxlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    // ISO-ish timestamp; launchd captures stdout to StandardOutPath.
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    fprintf(stdout, "%s  %s\n",
            [[df stringFromDate:[NSDate date]] UTF8String],
            [msg UTF8String]);
    fflush(stdout);
}

/// Seconds since the last HID event from any device on this Mac.
/// Returns -1 if the property could not be read.
static NSTimeInterval idleSeconds(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOHIDSystem"));
    if (!svc) return -1;

    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(svc, &props,
                                                         kCFAllocatorDefault, 0);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !props) return -1;

    NSTimeInterval secs = -1;
    CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, CFSTR("HIDIdleTime"));
    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) {
        int64_t ns = 0;
        if (CFNumberGetValue(n, kCFNumberSInt64Type, &ns)) secs = (double)ns / 1e9;
    }
    CFRelease(props);
    return secs;
}

static BOOL bluetoothOn(void) {
    return IOBluetoothPreferenceGetControllerPowerState() != 0;
}

/// Write VCP feature 0x60 (input source) over DDC/CI.
///
/// Packet layout, per the DDC/CI spec as implemented by m1ddc:
///   [0] 0x84  = 0x80 | payload length (4)
///   [1] 0x03  = "set VCP feature" opcode
///   [2] 0x60  = VCP feature code (input source)
///   [3] value high byte
///   [4] value low byte
///   [5] checksum: XOR of 0x6E, 0x51 and all preceding bytes
///
/// Packet format and constants verified against m1ddc v1.2.0 (sources/i2c.m).
///
/// Note the timing: DDC/CI writes are unacknowledged, so m1ddc sleeps before
/// each write and then sends the SAME packet twice, bailing only on error.
/// This is a repeat, not a retry — do not "optimise" it into break-on-success.
static void setDisplayInput(uint8_t value) {
    IOAVServiceRef svc = IOAVServiceCreate(kCFAllocatorDefault);
    if (!svc) {
        mxlog(@"DDC: no AVService (external display asleep or absent?)");
        return;
    }

    uint8_t data[6];
    data[0] = 0x84;                   // 0x80 | payload length (4)
    data[1] = 0x03;                   // set VCP feature
    data[2] = kVCPInputSource;        // 0x60
    data[3] = 0x00;                   // value, high byte
    data[4] = value;                  // value, low byte
    data[5] = 0x6E ^ kDDCDataAddress
            ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4];

    IOReturn err = kIOReturnSuccess;
    for (int i = 0; i < kDDCIterations; i++) {
        usleep(kDDCWaitMicros);
        err = IOAVServiceWriteI2C(svc, kDDCChipAddress, kDDCDataAddress,
                                  data, sizeof(data));
        if (err != kIOReturnSuccess) break;
    }

    if (err == kIOReturnSuccess) mxlog(@"DDC: set input to %u (0x%02X)", value, value);
    else                         mxlog(@"DDC: write failed (0x%08X)", err);

    CFRelease(svc);
}

// ------------------------------------------------------------ decision

static void considerSwitch(void) {
    if (gAttached.count > 0) return;          // something is still here

    NSDate *now = [NSDate date];

    NSTimeInterval drain = gDrainStart ? [now timeIntervalSinceDate:gDrainStart] : 0;
    if (drain > kDrainWindow) {
        mxlog(@"ignoring: devices drained over %.1fs (> %.1fs window)",
             drain, kDrainWindow);
        return;
    }

    if (gLastFire && [now timeIntervalSinceDate:gLastFire] < kCooldown) {
        mxlog(@"ignoring: within cooldown");
        return;
    }

    if (!bluetoothOn()) {
        mxlog(@"ignoring: Bluetooth is off");
        return;
    }

    NSTimeInterval idle = idleSeconds();
    if (idle < 0) {
        mxlog(@"warning: could not read HIDIdleTime; proceeding");
    } else if (idle > kIdleLimit) {
        mxlog(@"ignoring: idle for %.0fs", idle);
        return;
    }

    gLastFire = now;
    setDisplayInput(kTargetInput);
}

// ----------------------------------------------------------- callbacks

static NSString *productName(IOHIDDeviceRef device) {
    CFTypeRef p = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (p && CFGetTypeID(p) == CFStringGetTypeID()) return (__bridge NSString *)p;
    return nil;
}

static void deviceAdded(void *ctx, IOReturn result,
                        void *sender, IOHIDDeviceRef device) {
    NSString *name = productName(device);
    if (!name || ![name containsString:kProductMatch]) return;

    // A single peripheral often enumerates as several HID interfaces
    // (keyboard + consumer control, etc). Keying on product name collapses
    // those into one logical device, so we never depend on an interface count.
    if (![gAttached containsObject:name]) {
        [gAttached addObject:name];
        mxlog(@"attached: %@ (now %lu)", name, (unsigned long)gAttached.count);
    }
    gDrainStart = nil;
}

static void deviceRemoved(void *ctx, IOReturn result,
                          void *sender, IOHIDDeviceRef device) {
    NSString *name = productName(device);
    if (!name || ![name containsString:kProductMatch]) return;

    if ([gAttached containsObject:name]) {
        if (gAttached.count == 1 || gDrainStart == nil) {
            if (gDrainStart == nil) gDrainStart = [NSDate date];
        }
        [gAttached removeObject:name];
        mxlog(@"removed: %@ (now %lu)", name, (unsigned long)gAttached.count);
    }

    // Debounce: give any sibling device a moment to leave too, then decide.
    static dispatch_source_t timer;
    if (timer) dispatch_source_cancel(timer);
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                              DISPATCH_TIME_FOREVER, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        considerSwitch();
    });
    dispatch_resume(timer);
}

// ---------------------------------------------------------------- main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Optional: override target input on the command line, so the same
        // binary can serve both Macs. e.g. `mxswitch 15`
        if (argc > 1) {
            kTargetInput = (uint8_t)strtol(argv[1], NULL, 0);
        }

        gAttached = [NSMutableSet set];

        IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                                 kIOHIDOptionsTypeNone);
        if (!mgr) { mxlog(@"fatal: could not create IOHIDManager"); return 1; }

        NSDictionary *match = @{ @(kIOHIDVendorIDKey): @(kLogitechVendorID) };
        IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)match);

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, deviceAdded, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, deviceRemoved, NULL);

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                        kCFRunLoopDefaultMode);

        IOReturn kr = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
        if (kr != kIOReturnSuccess) {
            // Opening for enumeration only does not need Input Monitoring,
            // but a restrictive MDM profile can still refuse.
            mxlog(@"warning: IOHIDManagerOpen returned 0x%08X", kr);
        }

        mxlog(@"mxswitch started; target input 0x%02X", kTargetInput);
        CFRunLoopRun();
    }
    return 0;
}
