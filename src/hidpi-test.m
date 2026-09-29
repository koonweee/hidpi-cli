// Temporary HiDPI experiment. Private API declarations and mode synthesis
// adapted from https://github.com/pasky/hidpi-mirror (Petr Baudis, MIT).
// See licenses/hidpi-mirror-MIT.txt (distributed as hidpi-test-LICENSE.txt).
// No permanent display configuration is written.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach_time.h>

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@property(nonatomic) unsigned int serialNum, productID, vendorID;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static volatile sig_atomic_t interrupted = 0;
static NSString *verificationKey = nil;
static BOOL serviceMode = NO;
static void serviceStatus(NSString *phase) {
    if (!serviceMode) return;
    NSString *dir = NSProcessInfo.processInfo.environment[@"HIDPI_STATE_DIR"];
    if (!dir.length) return;
    NSDictionary *status = @{@"phase": phase, @"pid": @(getpid()), @"updated": @([[NSDate date] timeIntervalSince1970])};
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:0 error:NULL];
    [data writeToFile:[dir stringByAppendingPathComponent:@"service-status.json"] atomically:YES];
}
static NSURL *stateFile(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"HIDPI_STATE_DIR"];
    NSURL *directory = override.length ? [NSURL fileURLWithPath:override isDirectory:YES] :
        [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
            URLByAppendingPathComponent:@"hidpi" isDirectory:YES];
    return [directory URLByAppendingPathComponent:@"verified.json"];
}
static void rememberVerified(void) {
    if (!verificationKey) return;
    NSURL *url = stateFile();
    NSData *data = [NSData dataWithContentsOfURL:url];
    id old = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableDictionary *records = [old isKindOfClass:NSDictionary.class] ? [old mutableCopy] : [NSMutableDictionary dictionary];
    records[verificationKey] = @([[NSDate date] timeIntervalSince1970]);
    NSError *error = nil;
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:&error];
    NSData *updated = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingPrettyPrinted error:&error];
    if (!ok || !updated || ![updated writeToURL:url options:NSDataWritingAtomic error:&error])
        fprintf(stderr, "Could not remember this verified mode: %s\n", error.localizedDescription.UTF8String);
}
static void onSignal(int sig) { interrupted = sig; }
static double now(void) {
    mach_timebase_info_data_t t;
    mach_timebase_info(&t);
    return (double)mach_continuous_time() * t.numer / t.denom / 1e9;
}
static void pump(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}
static void die(NSString *message) {
    serviceStatus(@"failed");
    fprintf(stderr, "hidpi-test: %s\n", message.UTF8String);
    exit(1);
}
static void checked(CGError error, NSString *operation) {
    if (error != kCGErrorSuccess)
        die([NSString stringWithFormat:@"%@ failed (CoreGraphics %d).", operation, error]);
}
static NSArray<NSNumber *> *onlineDisplays(void) {
    uint32_t count = 0;
    checked(CGGetOnlineDisplayList(0, NULL, &count), @"Reading displays");
    if (!count) return @[];
    CGDirectDisplayID *ids = calloc(count, sizeof(*ids));
    if (!ids) die(@"Out of memory.");
    CGError e = CGGetOnlineDisplayList(count, ids, &count);
    NSMutableArray *result = [NSMutableArray array];
    if (e == kCGErrorSuccess)
        for (uint32_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    free(ids);
    checked(e, @"Reading displays");
    return result;
}
static NSString *nameFor(CGDirectDisplayID display) {
    for (NSScreen *screen in NSScreen.screens)
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display)
            return screen.localizedName;
    return [NSString stringWithFormat:@"Display %u", display];
}
static BOOL wanted(CGDisplayModeRef m, unsigned w, unsigned h) {
    return m && CGDisplayModeGetWidth(m) == w && CGDisplayModeGetHeight(m) == h &&
        CGDisplayModeGetPixelWidth(m) == w * 2 && CGDisplayModeGetPixelHeight(m) == h * 2;
}
static NSArray *availableModes(CGDirectDisplayID display) {
    // Some macOS versions return different sets with the duplicate-mode flag.
    // Keep both sets, and also inspect the current mode independently.
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    NSArray *normal = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, NULL));
    NSArray *expanded = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options));
    NSMutableArray *result = [NSMutableArray arrayWithArray:normal ?: @[]];
    NSMutableSet *seen = [NSMutableSet set];
    for (id item in result) [seen addObject:@(CGDisplayModeGetIODisplayModeID((__bridge CGDisplayModeRef)item))];
    for (id item in expanded) {
        NSNumber *key = @(CGDisplayModeGetIODisplayModeID((__bridge CGDisplayModeRef)item));
        if (![seen containsObject:key]) { [result addObject:item]; [seen addObject:key]; }
    }
    id current = CFBridgingRelease(CGDisplayCopyDisplayMode(display));
    if (current && ![seen containsObject:@(CGDisplayModeGetIODisplayModeID((__bridge CGDisplayModeRef)current))])
        [result addObject:current];
    return result;
}
static void describeMode(CGDisplayModeRef m) {
    fprintf(stderr, "  %zu × %zu logical; %zu × %zu pixels; %.2f Hz; ID %u; GUI %s\n",
            CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
            CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
            CGDisplayModeGetRefreshRate(m), CGDisplayModeGetIODisplayModeID(m),
            CGDisplayModeIsUsableForDesktopGUI(m) ? "yes" : "no");
}
static void dumpModes(CGDirectDisplayID display, const char *label) {
    fprintf(stderr, "\n%s [ID %u, online %d, active %d]:\n", label, display,
            CGDisplayIsOnline(display), CGDisplayIsActive(display));
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
    if (current) { fputs("Current:\n", stderr); describeMode(current); CFRelease(current); }
    else fputs("Current mode: unavailable\n", stderr);
    NSArray *modes = availableModes(display);
    fprintf(stderr, "Available modes (%lu, merged default/expanded/current):\n", (unsigned long)modes.count);
    for (id item in modes) describeMode((__bridge CGDisplayModeRef)item);
}

@interface Snapshot : NSObject
@property(nonatomic) CGDirectDisplayID display;
@property(nonatomic) CGPoint origin;
@property(retain) id modeObject;
@property(retain) id uuidObject;
@end
@implementation Snapshot
@end
static NSArray<Snapshot *> *capture(void) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSNumber *number in onlineDisplays()) {
        CGDirectDisplayID d = number.unsignedIntValue;
        if (CGDisplayIsInMirrorSet(d)) die(@"Disable existing display mirroring before this experiment.");
        if (!CGDisplayIsActive(d)) die(@"An online display is inactive. Enable it before this experiment.");
        Snapshot *s = [Snapshot new];
        s.display = d;
        s.origin = CGDisplayBounds(d).origin;
        s.modeObject = CFBridgingRelease(CGDisplayCopyDisplayMode(d));
        s.uuidObject = CFBridgingRelease(CGDisplayCreateUUIDFromDisplayID(d));
        if (!s.modeObject || !s.uuidObject) die(@"Could not save the current display configuration.");
        [result addObject:s];
    }
    return result;
}
static BOOL restore(NSArray<Snapshot *> *saved) {
    CGDisplayConfigRef config = NULL;
    CGError e = CGBeginDisplayConfiguration(&config);
    if (e != kCGErrorSuccess) {
        fprintf(stderr, "Could not start restoration: %d. Check System Settings → Displays.\n", e);
        return NO;
    }
    BOOL complete = YES;
    for (Snapshot *s in saved) {
        CGDirectDisplayID d = CGDisplayGetDisplayIDFromUUID((__bridge CFUUIDRef)s.uuidObject);
        if (!d || !CGDisplayIsOnline(d)) {
            fprintf(stderr, "A saved display is disconnected; skipping it.\n");
            complete = NO;
            continue;
        }
        CGError a = CGConfigureDisplayMirrorOfDisplay(config, d, kCGNullDirectDisplay);
        CGError b = CGConfigureDisplayWithDisplayMode(config, d, (__bridge CGDisplayModeRef)s.modeObject, NULL);
        CGError c = CGConfigureDisplayOrigin(config, d, (int32_t)s.origin.x, (int32_t)s.origin.y);
        if (a || b || c) {
            fprintf(stderr, "Restoration could not be configured for display %u (%d/%d/%d).\n", d, a, b, c);
            CGCancelDisplayConfiguration(config);
            return NO;
        }
    }
    e = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (e != kCGErrorSuccess) {
        fprintf(stderr, "Restoration failed (%d). Check System Settings → Displays.\n", e);
        return NO;
    }
    pump(0.5);
    for (Snapshot *s in saved) {
        CGDirectDisplayID d = CGDisplayGetDisplayIDFromUUID((__bridge CFUUIDRef)s.uuidObject);
        CGDisplayModeRef m = d ? CGDisplayCopyDisplayMode(d) : NULL;
        CGDisplayModeRef before = (__bridge CGDisplayModeRef)s.modeObject;
        if (!m || CGDisplayModeGetIODisplayModeID(m) != CGDisplayModeGetIODisplayModeID(before) ||
            CGDisplayIsInMirrorSet(d) || !CGPointEqualToPoint(CGDisplayBounds(d).origin, s.origin)) complete = NO;
        if (m) CFRelease(m);
    }
    puts(complete ? "Previous display modes and layout restored." :
         "Restoration was requested, but not fully verified. Check System Settings → Displays.");
    return complete;
}

static NSTask *launchChild(NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    task.arguments = arguments;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
    task.standardError = NSFileHandle.fileHandleWithStandardError;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) die(error.localizedDescription);
    return task;
}

static int worker(CGDirectDisplayID target, unsigned w, unsigned h) {
    // The supervisor can stop the owner AND its controller as one process group.
    if (setpgid(0, 0) != 0) die(@"Could not isolate the test helper process group.");
    // If the supervisor dies, the pipe closes and this worker exits too.
    signal(SIGPIPE, SIG_DFL);
    NSArray<Snapshot *> *saved = capture();
    if (!CGDisplayIsActive(target)) die(@"Target display is no longer active.");
    for (NSString *n in @[@"CGVirtualDisplay", @"CGVirtualDisplayDescriptor", @"CGVirtualDisplaySettings", @"CGVirtualDisplayMode"])
        if (!NSClassFromString(n)) die(@"The private virtual-display API is unavailable on this macOS version.");
    CGVirtualDisplayDescriptor *desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    desc.queue = dispatch_get_main_queue();
    desc.name = @"Temporary HiDPI Test";
    desc.sizeInMillimeters = CGDisplayScreenSize(target);
    desc.maxPixelsWide = MAX(w * 2, 5120u);
    desc.maxPixelsHigh = MAX(h * 2, 3200u);
    desc.redPrimary = CGPointMake(0.64, 0.33);
    desc.greenPrimary = CGPointMake(0.30, 0.60);
    desc.bluePrimary = CGPointMake(0.15, 0.06);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);
    desc.vendorID = 0xF0F0;
    desc.productID = arc4random_uniform(0xFFFE) + 1;
    desc.serialNum = arc4random();
    desc.terminationHandler = ^(__unused id a, __unused id b) { exit(1); };
    __attribute__((objc_precise_lifetime)) CGVirtualDisplay *virtualDisplay =
        [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    if (!virtualDisplay) die(@"macOS refused to create a virtual display.");
    CGDirectDisplayID vid = virtualDisplay.displayID;
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1;
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    NSMutableArray *modes = [NSMutableArray array];
    unsigned sizes[][2] = {{w*2,h*2}, {desc.maxPixelsWide,desc.maxPixelsHigh},
        {3840,2400}, {3360,2100}, {3200,2000}, {2880,1800}, {2560,1600}, {1920,1200}};
    NSMutableSet *seen = [NSMutableSet set];
    for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) {
        NSString *key = [NSString stringWithFormat:@"%u:%u",sizes[i][0],sizes[i][1]];
        if ([seen containsObject:key]) continue;
        id m = [[modeClass alloc] initWithWidth:sizes[i][0] height:sizes[i][1] refreshRate:60];
        if (!m) die(@"Virtual mode creation failed.");
        [modes addObject:m];
        [seen addObject:key];
    }
    settings.modes = modes;
    if (![virtualDisplay applySettings:settings]) die(@"macOS refused the virtual mode list.");

    // CoreGraphics may cache an empty mode list in the creator process if it
    // queried displays before creation. Inspect/configure in a fresh process,
    // launched only AFTER the virtual display exists. Keep its owner alive.
    NSMutableArray *layout = [NSMutableArray array];
    for (Snapshot *s in saved)
        [layout addObject:@[@(s.display), @(s.origin.x), @(s.origin.y)]];
    NSData *json = [NSJSONSerialization dataWithJSONObject:layout options:0 error:NULL];
    if (!json) die(@"Could not pass the saved layout to the display controller.");
    NSString *layoutString = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // Give WindowServer a chance to publish the display before the controller's
    // first CoreGraphics query, which establishes that process's mode cache.
    double settle = now() + 0.5;
    while (now() < settle) pump(0.05);
    NSTask *controller = launchChild(@[@"--controller", @(target).stringValue, @(vid).stringValue,
        @(w).stringValue, @(h).stringValue, @(getpid()).stringValue, layoutString]);
    while (controller.running) {
        pump(0.1);
        if (getppid() == 1) {
            kill(controller.processIdentifier, SIGKILL);
            return 1;
        }
    }
    return controller.terminationStatus;
}

static int controlDisplay(CGDirectDisplayID target, CGDirectDisplayID vid, unsigned w, unsigned h,
                          pid_t owner, NSString *layoutString) {
    if (setpgid(0, owner) != 0) die(@"Could not join the test helper process group.");
    NSArray *layout = [NSJSONSerialization JSONObjectWithData:[layoutString dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0 error:NULL];
    if (![layout isKindOfClass:NSArray.class]) die(@"Invalid saved layout.");
    for (id row in layout) {
        if (![row isKindOfClass:NSArray.class] || [row count] != 3) die(@"Invalid saved layout row.");
        for (id value in row) if (![value isKindOfClass:NSNumber.class]) die(@"Invalid saved layout value.");
    }
    fprintf(stderr, "Inspecting virtual display %u from a fresh helper process.\n", vid);

    CGDisplayModeRef desired = NULL;
    double deadline = now() + 5;
    while (!desired && now() < deadline) {
        NSArray *available = availableModes(vid);
        for (id item in available) {
            CGDisplayModeRef m = (__bridge CGDisplayModeRef)item;
            if (wanted(m, w, h)) { desired = CGDisplayModeRetain(m); break; }
        }
        if (!desired) pump(0.25);
    }
    if (!desired) {
        fprintf(stderr, "\nHiDPI diagnostics — macOS %s\n", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
        fprintf(stderr, "Fresh-process query: requested %u × %u logical / %u × %u pixels.\n", w, h, w*2, h*2);
        dumpModes(vid, "Virtual display");
        dumpModes(target, "Physical display");
        die(@"macOS did not expose the requested 2× HiDPI mode. Diagnostic list above; restoring now.");
    }
    CGDisplayConfigRef cfg = NULL;
    checked(CGBeginDisplayConfiguration(&cfg), @"Starting temporary configuration");
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(vid);
    CGError a = wanted(current, w, h) ? kCGErrorSuccess : CGConfigureDisplayWithDisplayMode(cfg, vid, desired, NULL);
    if (current) CFRelease(current);
    CGError b = CGConfigureDisplayMirrorOfDisplay(cfg, target, vid);
    CGDisplayModeRelease(desired);
    if (a || b) { CGCancelDisplayConfiguration(cfg); die(@"Could not configure the temporary mirror."); }
    checked(CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly), @"Applying temporary mirror");

    deadline = now() + 4;
    BOOL verified = NO;
    while (now() < deadline) {
        pump(0.25);
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(vid);
        if (!m) m = CGDisplayCopyDisplayMode(target);
        verified = CGDisplayMirrorsDisplay(target) == vid && wanted(m, w, h);
        if (m) CFRelease(m);
        if (verified) break;
    }
    if (!verified) {
        dumpModes(vid, "Virtual display after mirroring");
        dumpModes(target, "Physical display after mirroring");
        die(@"The mirror did not report the requested HiDPI desktop. Ending the experiment.");
    }
    checked(CGBeginDisplayConfiguration(&cfg), @"Positioning the temporary display");
    for (NSArray<NSNumber *> *row in layout) {
        CGDirectDisplayID display = row[0].unsignedIntValue;
        CGError e = CGConfigureDisplayOrigin(cfg, display == target ? vid : display,
                                            row[1].intValue, row[2].intValue);
        if (e) { CGCancelDisplayConfiguration(cfg); die(@"Could not preserve the display layout."); }
    }
    checked(CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly), @"Preserving display layout");
    CGDisplayModeRef finalMode = CGDisplayCopyDisplayMode(vid);
    if (!finalMode) finalMode = CGDisplayCopyDisplayMode(target);
    BOOL finalVerified = wanted(finalMode, w, h) && CGDisplayMirrorsDisplay(target) == vid;
    if (finalMode) CFRelease(finalMode);
    if (!finalVerified) die(@"HiDPI verification failed after positioning the display.");
    printf("READY %u %u\n", w, h);
    fflush(stdout);
    while (YES) {
        pump(0.5);
        if (getppid() != owner || !CGDisplayIsOnline(target) || CGDisplayMirrorsDisplay(target) != vid) return 1;
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(vid);
        if (!m) m = CGDisplayCopyDisplayMode(target);
        BOOL matches = wanted(m, w, h);
        if (m) CFRelease(m);
        if (!matches) return 1;
    }
}

static void stopTask(NSTask *task) {
    // Always clean up the group, even if the owner exited before its controller.
    pid_t pid = task.processIdentifier;
    if (pid <= 1) return;
    kill(-pid, SIGTERM);
    if (task.running) kill(pid, SIGTERM);
    double until = now() + 2;
    while ((task.running || kill(-pid, 0) == 0) && now() < until) pump(0.05);
    if (task.running || kill(-pid, 0) == 0) {
        kill(-pid, SIGKILL);
        if (task.running) kill(pid, SIGKILL);
        until = now() + 2;
        while (task.running && now() < until) pump(0.05);
    }
}

// Runs in a separate process from the private API, so a blocked WindowServer
// transaction in the worker cannot block the countdown or Ctrl-C handling.
static int supervise(NSArray<NSString *> *arguments, BOOL testFixture) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "Could not launch helper: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    [pipe.fileHandleForWriting closeFile];
    int fd = pipe.fileHandleForReading.fileDescriptor;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    NSMutableString *output = [NSMutableString string];
    double deadline = now() + (testFixture ? 2 : 15);
    BOOL ready = NO, keep = NO, timedOut = NO;
    int result = 0;
    while (task.running && !interrupted) {
        char buffer[1024];
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            NSString *chunk = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)n encoding:NSUTF8StringEncoding];
            if (chunk) [output appendString:chunk];
            if (!ready && [output containsString:@"READY "]) {
                ready = YES;
                deadline = now() + (testFixture ? 0.3 : 20);
                if (!testFixture) {
                    rememberVerified();
                    if (serviceMode) {
                        keep = YES;
                        serviceStatus(@"running");
                        puts("HiDPI verified. Background service running.");
                    } else {
                        puts("HiDPI verified. Restoring in 20 seconds.");
                        puts("Type k then Enter to keep running; q then Enter or Ctrl-C to restore now.");
                    }
                }
            }
        }
        if (!testFixture && !serviceMode) {
            struct pollfd p = { .fd = STDIN_FILENO, .events = POLLIN };
            if (poll(&p, 1, 0) > 0 && (p.revents & (POLLIN | POLLHUP))) {
                char input[128];
                ssize_t got = read(STDIN_FILENO, input, sizeof(input));
                if (got <= 0) { result = 130; break; }
                NSString *line = [[[NSString alloc] initWithBytes:input length:(NSUInteger)got encoding:NSUTF8StringEncoding]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([line.lowercaseString isEqualToString:@"q"]) { result = 130; break; }
                if (ready && [line.lowercaseString isEqualToString:@"k"]) {
                    keep = YES;
                    puts("Keeping this test running. Leave this Terminal open. Ctrl-C or q + Enter restores it.");
                }
            }
        }
        if (!keep && now() >= deadline) {
            timedOut = YES;
            if (!ready) { fputs("Setup timed out. Stopping helper.\n", stderr); result = 1; }
            else puts("Test window ended.");
            break;
        }
        pump(0.05);
    }
    if (!task.running && !timedOut && !interrupted) {
        fprintf(stderr, "Helper exited (status %d).\n", task.terminationStatus);
        result = 1;
    }
    stopTask(task);
    if (task.running) { fputs("Could not stop the helper.\n", stderr); result = 1; }
    if (testFixture) {
        int childPID = 0;
        const char *childLine = strstr(output.UTF8String, "CHILD ");
        if (childLine) sscanf(childLine, "CHILD %d", &childPID);
        double until = now() + 2;
        while (childPID > 1 && kill(childPID, 0) == 0 && now() < until) pump(0.05);
        BOOL childGone = childPID > 1 && kill(childPID, 0) == -1 && errno == ESRCH;
        return (ready && timedOut && !task.running && childGone) ? 0 : 1;
    }
    return result;
}

static unsigned parseNumber(const char *s, unsigned min, unsigned max) {
    char *end = NULL;
    unsigned long n = strtoul(s, &end, 10);
    if (!*s || *end || n < min || n > max) die(@"Invalid numeric argument. Use --help.");
    return (unsigned)n;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        if (argc == 2 && !strcmp(argv[1], "--watchdog-fixture")) {
            // No display API calls: exercise cleanup of a worker and controller.
            if (setpgid(0, 0) != 0) die(@"Fixture process group failed.");
            signal(SIGTERM, SIG_IGN);
            __attribute__((objc_precise_lifetime)) NSTask *child = launchChild(@[@"--watchdog-leaf", @(getpid()).stringValue]);
            (void)child;
            for (;;) pause();
        }
        if (argc == 3 && !strcmp(argv[1], "--watchdog-leaf")) {
            if (setpgid(0, (pid_t)parseNumber(argv[2], 2, INT_MAX)) != 0) die(@"Fixture child process group failed.");
            signal(SIGTERM, SIG_IGN);
            printf("CHILD %d\nREADY fixture\n", getpid());
            for (;;) pause();
        }
        if (argc == 8 && !strcmp(argv[1], "--controller")) {
            @try { return controlDisplay(parseNumber(argv[2], 1, UINT32_MAX), parseNumber(argv[3], 1, UINT32_MAX),
                parseNumber(argv[4], 800, 2560), parseNumber(argv[5], 600, 1600),
                (pid_t)parseNumber(argv[6], 2, INT_MAX), @(argv[7])); }
            @catch (NSException *e) { die([NSString stringWithFormat:@"Controller exception: %@", e.reason]); }
        }
        if (argc == 5 && !strcmp(argv[1], "--worker")) {
            @try { return worker(parseNumber(argv[2], 1, UINT32_MAX), parseNumber(argv[3], 800, 2560), parseNumber(argv[4], 600, 1600)); }
            @catch (NSException *e) { die([NSString stringWithFormat:@"Private API exception: %@", e.reason]); }
        }
        if (argc == 2 && !strcmp(argv[1], "--self-test")) {
            int result = supervise(@[@"--watchdog-fixture"], YES);
            puts(result ? "FAIL: watchdog" : "PASS: independent timeout and forced termination of owner and controller (no displays changed)");
            return result;
        }
        if (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) {
            puts("Usage: hidpi-test [width height [display-ID]]\n"
                 "       hidpi-test --list\n\n"
                 "Defaults to 1920 × 1200 HiDPI at 60 Hz. Selects an external display.\n"
                 "Creates a temporary virtual display and mirrors it to the selected monitor.\n"
                 "After verification, restores after 20 seconds unless you type k + Enter.\n"
                 "Ctrl-C or q + Enter stops the helper and restores saved modes and layout.\n"
                 "Uses private macOS APIs; compatibility must be tested on your Mac.\n"
                 "No sudo, login item, or permanent display override. Must run in Terminal.\n"
                 "Supported test sizes: 800–2560 wide, 600–1600 high.\n"
                 "--self-test checks the watchdog without touching displays.");
            return 0;
        }
        serviceMode = argc == 5 && !strcmp(argv[1], "--service");
        if (serviceMode) {
            signal(SIGINT, onSignal);
            signal(SIGTERM, onSignal);
            signal(SIGHUP, onSignal);
            serviceStatus(@"starting");
            unsigned w = parseNumber(argv[2], 800, 2560), h = parseNumber(argv[3], 600, 1600);
            CFUUIDRef uuid = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)@(argv[4]));
            if (!uuid) die(@"Invalid saved display UUID.");
            CGDirectDisplayID target = 0;
            double until = now() + 30;
            while (!interrupted && now() < until) {
                // UUID lookup does not initialize the WindowServer connection
                // itself in a fresh launchd process (CGS_REQUIRE_INIT asserts).
                uint32_t onlineCount = 0;
                checked(CGGetOnlineDisplayList(0, NULL, &onlineCount), @"Initializing display connection");
                target = CGDisplayGetDisplayIDFromUUID(uuid);
                if (target && CGDisplayIsActive(target)) break;
                pump(0.25);
            }
            CFRelease(uuid);
            if (interrupted) { serviceStatus(@"stopped"); return 0; }
            if (!target || !CGDisplayIsActive(target)) die(@"Saved display unavailable after 30 seconds; not retrying automatically.");
            verificationKey = [NSString stringWithFormat:@"%@|%@|virtual-v1|%ux%u@60", @(argv[4]),
                NSProcessInfo.processInfo.operatingSystemVersionString, w, h];
            NSData *data = [NSData dataWithContentsOfURL:stateFile()];
            id records = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if (![records isKindOfClass:NSDictionary.class] || !records[verificationKey])
                die(@"Mode not verified on this monitor/macOS version. Run the foreground switcher first.");
            NSArray<Snapshot *> *saved = capture();
            int result = supervise(@[@"--worker", @(target).stringValue, @(w).stringValue, @(h).stringValue], NO);
            serviceStatus(@"restoring");
            if (!restore(saved)) { serviceStatus(@"restore-failed"); return 1; }
            serviceStatus(result ? @"failed-restored" : @"stopped");
            return result;
        }
        BOOL list = argc == 2 && !strcmp(argv[1], "--list");
        if (!list && argc != 1 && argc != 3 && argc != 4) die(@"Invalid arguments. Use --help.");
        unsigned w = argc >= 3 ? parseNumber(argv[1], 800, 2560) : 1920;
        unsigned h = argc >= 3 ? parseNumber(argv[2], 600, 1600) : 1200;
        NSArray<NSNumber *> *all = onlineDisplays();
        if (!all.count) die(@"No displays visible. Run in Terminal in your logged-in Mac desktop session.");
        NSMutableArray<NSNumber *> *external = [NSMutableArray array];
        for (NSNumber *number in all) {
            CGDirectDisplayID d = number.unsignedIntValue;
            if (list) printf("%u  %s%s\n", d, nameFor(d).UTF8String, CGDisplayIsBuiltin(d) ? " (built-in)" : "");
            if (!CGDisplayIsBuiltin(d) && CGDisplayIsActive(d)) [external addObject:number];
        }
        if (list) return 0;
        if (!isatty(STDIN_FILENO)) die(@"Run interactively in Terminal (input is not a terminal).");
        if (!external.count) die(@"No active external display found.");
        CGDirectDisplayID target = 0;
        if (argc == 4) target = parseNumber(argv[3], 1, UINT32_MAX);
        else if (external.count == 1) target = external[0].unsignedIntValue;
        else {
            for (NSNumber *n in external) printf("%u  %s\n", n.unsignedIntValue, nameFor(n.unsignedIntValue).UTF8String);
            printf("Display ID to test (q to quit): ");
            char line[64];
            if (!fgets(line, sizeof(line), stdin) || line[0] == 'q') return 0;
            line[strcspn(line, "\r\n")] = 0;
            target = parseNumber(line, 1, UINT32_MAX);
        }
        if (![external containsObject:@(target)]) die(@"Choose an active external display from --list.");
        NSArray<Snapshot *> *saved = capture();
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(target);
        if (uuid) {
            NSString *uuidString = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
            CFRelease(uuid);
            verificationKey = [NSString stringWithFormat:@"%@|%@|virtual-v1|%ux%u@60", uuidString,
                NSProcessInfo.processInfo.operatingSystemVersionString, w, h];
        }
        signal(SIGINT, onSignal);
        signal(SIGTERM, onSignal);
        signal(SIGHUP, onSignal);
        printf("Testing %u × %u HiDPI (renders %u × %u) on %s [ID %u].\n", w, h, w*2, h*2, nameFor(target).UTF8String, target);
        puts("Setup has a 15-second timeout. The 20-second trial starts after HiDPI verification.");
        int result = supervise(@[@"--worker", @(target).stringValue, @(w).stringValue, @(h).stringValue], NO);
        puts("Restoring saved display configuration…");
        if (!restore(saved)) result = 1;
        return interrupted ? 128 + interrupted : result;
    }
}
