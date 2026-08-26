//
//  mxswitch.m
//
//  Watches for Logitech MX peripherals leaving this Mac (via Easy-Switch)
//  and pushes the external display over to the other input using DDC/CI.
//
//  Event-driven: no polling. IOHIDManager calls us on device attach/remove.
//
//  Build and install (compiles, bundles, signs, loads the LaunchAgent):
//    ./build.sh 16       # e.g. personal Mac, hands monitor to input 16 (DisplayPort #2)
//    ./build.sh 15       # e.g. work Mac, hands monitor to input 15 (DisplayPort #1)
//
//  Bundle / LaunchAgent identifier: com.mackerron.mxswitch
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
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#include <unistd.h>
#include <time.h>
#include <math.h>

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
static const useconds_t kDDCWaitMicros = 50000; // some displays need 50000

// Only devices whose product name contains this are counted.
static NSString *const kProductMatch = @"MX";

// All matching devices must disappear within this window for it to count as
// a deliberate Easy-Switch rather than independent idle drop-offs.
static const NSTimeInterval kDrainWindow = 2.0;

// Ignore the event if there has been no human input for longer than this.
static const NSTimeInterval kIdleLimit = INFINITY;

// Refuse to fire twice in quick succession.
static const NSTimeInterval kCooldown = 5.0;

// After waking, ignore device removals for this long.
static const NSTimeInterval kWakeGuard = 5.0;

// ------------------------------------------------- private API surface

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t offset,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);


// ---------------------------------------------------------------- state

static NSMutableSet<NSString *> *gAttached;   // product names currently present
static NSTimeInterval gDrainStart;            // monotonic; 0 = not draining
static NSTimeInterval gLastFire;              // monotonic; 0 = never fired

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

/// Seconds from an arbitrary fixed origin, monotonic and immune to NTP steps
/// or manual clock changes.
///
/// CLOCK_MONOTONIC_RAW keeps counting while the system is asleep, which is
/// what we want: if the Mac sleeps between one device leaving and the next,
/// that really was a long gap and should not read as a simultaneous drain.
/// CLOCK_UPTIME_RAW (and mach_absolute_time) pause during sleep and would
/// make an overnight gap look instantaneous — do not substitute them here.
static NSTimeInterval nowSecs(void) {
    return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
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

/// Sleep/wake suppression.
///
/// When the Mac sleeps, the MX devices disconnect — and those removals look
/// exactly like an Easy-Switch press: simultaneous, and with a low idle time
/// if you were typing right up to closing the lid. So we track power state
/// and refuse to switch while asleep, or for a short window after waking
/// (removals queued during the sleep transition can arrive post-wake).
static io_connect_t gRootPort;
static BOOL gSleeping;
static NSTimeInterval gWakeGuardUntil;   // monotonic; 0 = no guard

static void powerCallback(void *refcon, io_service_t service,
                          natural_t messageType, void *messageArgument) {
    switch (messageType) {

        case kIOMessageCanSystemSleep:
            // Idle sleep is being proposed. We never veto — and we MUST
            // answer, or the system waits out a 30-second timeout before
            // sleeping every single time.
            IOAllowPowerChange(gRootPort, (long)messageArgument);
            break;

        case kIOMessageSystemWillSleep:
            gSleeping = YES;
            mxlog(@"system sleeping; switching suppressed");
            // Mandatory acknowledgement, same reasoning as above.
            IOAllowPowerChange(gRootPort, (long)messageArgument);
            break;

        case kIOMessageSystemHasPoweredOn:
            gSleeping = NO;
            gWakeGuardUntil = nowSecs() + kWakeGuard;
            gDrainStart = 0;
            mxlog(@"system awake; switching suppressed for %.0fs", kWakeGuard);
            break;

        default:
            break;
    }
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
    IOReturn firstErr = kIOReturnError;
    for (int i = 0; i < kDDCIterations; i++) {
        usleep(kDDCWaitMicros);
        err = IOAVServiceWriteI2C(svc, kDDCChipAddress, kDDCDataAddress,
                                  data, sizeof(data));
        if (i == 0) firstErr = err;
        if (err != kIOReturnSuccess) break;
    }

    // Switching input tears down the DisplayPort link on this Mac, which
    // invalidates the AVService's mach port. So the repeat write typically
    // comes back MACH_SEND_INVALID_DEST (0x10000003) even though the switch
    // worked. Only the first write's result tells us anything.
    if (firstErr == kIOReturnSuccess) {
        mxlog(@"DDC: set input to %u (0x%02X)", value, value);
        if (err != kIOReturnSuccess) {
            mxlog(@"  (repeat write returned 0x%08X — expected on input switch)",
                  err);
        }
    } else {
        mxlog(@"DDC: write failed (0x%08X)", firstErr);
    }

    CFRelease(svc);
}

// ------------------------------------------------------------ decision

static void considerSwitch(void) {
    if (gAttached.count > 0) return;          // something is still here

    mxlog(@"considering switch...");
    NSTimeInterval now = nowSecs();

    NSTimeInterval drain = gDrainStart ? (now - gDrainStart) : 0;
    if (drain > kDrainWindow) {
        mxlog(@"ignoring: devices drained over %.1fs (> %.1fs window)",
             drain, kDrainWindow);
        return;
    }

    if (gLastFire && (now - gLastFire) < kCooldown) {
        mxlog(@"ignoring: within cooldown");
        return;
    }

    if (gSleeping) {
        mxlog(@"ignoring: system is sleeping");
        return;
    }

    if (gWakeGuardUntil && now < gWakeGuardUntil) {
        mxlog(@"ignoring: within %.0fs of wake", kWakeGuard);
        return;
    }

    NSTimeInterval idle = idleSeconds();
    if (idle < 0) {
        mxlog(@"warning: could not read HIDIdleTime; proceeding");
    } else if (idle > kIdleLimit) {
        mxlog(@"ignoring: idle for %.0fs", idle);
        return;
    }

    mxlog(@"  writing DDC...");
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
    gDrainStart = 0;
}

static void deviceRemoved(void *ctx, IOReturn result,
                          void *sender, IOHIDDeviceRef device) {
    NSString *name = productName(device);
    if (!name || ![name containsString:kProductMatch]) return;

    if ([gAttached containsObject:name]) {
        if (gDrainStart == 0) gDrainStart = nowSecs();
        [gAttached removeObject:name];
        mxlog(@"removed: %@ (now %lu)", name, (unsigned long)gAttached.count);
    }

    // No debounce needed: we only act once the set is empty, so the final
    // removal is itself the trigger. The drain window below decides whether
    // the devices left together (Easy-Switch) or drifted off independently.
    if (gAttached.count == 0) considerSwitch();
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

        // Sleep/wake notifications. Public API, no TCC prompt.
        IONotificationPortRef pmPort = NULL;
        io_object_t pmNotifier = 0;
        gRootPort = IORegisterForSystemPower(NULL, &pmPort,
                                             powerCallback, &pmNotifier);
        if (gRootPort == MACH_PORT_NULL) {
            mxlog(@"warning: IORegisterForSystemPower failed; "
                   "sleep suppression disabled");
        } else {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(pmPort),
                               kCFRunLoopDefaultMode);
        }

        // Deliberately NOT calling IOHIDManagerOpen(). Opening the manager
        // requires Input Monitoring (TCC) and would prompt the user — but we
        // only need to know when devices appear and disappear, and the
        // matching/removal callbacks fire on the scheduled run loop without
        // an open. Keeping it closed means no permission prompt, no grant to
        // re-approve after every rebuild, and nothing for MDM to refuse.
        //
        // If a future macOS stops delivering callbacks without an open, the
        // TCC-free fallback is IOServiceAddMatchingNotification on
        // IOHIDDevice via plain IOKit rather than the HID manager.

        mxlog(@"mxswitch started; target input %u (0x%02X)",
              kTargetInput, kTargetInput);
        CFRunLoopRun();
    }
    return 0;
}
