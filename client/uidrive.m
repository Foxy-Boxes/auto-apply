/*
 * uidrive.m -- unified out-of-process UI driver for macOS.
 *
 * One API over two backends, with automatic fallback:
 *
 *   - STANDARD backend: drive any app through the Accessibility API
 *     (locate elements, AXPress) and CGEvent (real clicks / keystrokes),
 *     and capture its on-screen window. No injection, no re-signing.
 *
 *   - VIRTUAL-DISPLAY backend: create a software display with the private
 *     CGVirtualDisplay API (the local analog of a VM's virtual GPU), move the
 *     target window onto it so it leaves the real screens, and capture that
 *     display. Driving is identical (CGEvent at global coords).
 *
 * The virtual display is private API and version-fragile. uidrive probes it at
 * runtime; if it is missing or fails, every command falls back to the standard
 * backend automatically. The virtual display is only created when you ask for
 * it (`isolate on`, or `session --isolate`), and it lives only as long as the
 * session process, so isolation runs inside `session`.
 *
 * Usage:
 *   uidrive trust                         check / raise Accessibility permission
 *   uidrive info  <pid|app>               what each backend can do for this app
 *   uidrive do    <pid|app> <cmd> [args]  run one command on the real screen
 *   uidrive session <pid|app> [--isolate] interactive REPL (holds a vdisplay)
 *   uidrive display [w h]                 hold a virtual display until stdin closes
 *
 * Commands (in `do` and in a session):
 *   tree [depth] | find <text> | press <text> | click <text>
 *   type <text>  | key <name> [mods] | keys <chord>... (Emacs notation: C-x M-x S-p RET)
 *   keydown|keyup <name> [mods] | hold <name> <ms> [mods] | keyscript <file> | sleep <ms>
 *   activate | resize <w> <h>
 *   capture <file.png> | record start <file.mp4> [fps] [display] | record stop
 * Session also: target pid|hid|shim <sock> | isolate on|off | info | help | quit
 * UIDRIVE_POST=pid sends keys to the process instead of the frontmost app;
 * UIDRIVE_SHIM=<sock> sends them in-process through appshim (see shimCommand).
 */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* private SPI: the CGWindowID backing an AX element (stable, widely used) */
extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);

/* ================================================================= */
/* Accessibility helpers                                             */
/* ================================================================= */

static NSString *axString(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) s = [(__bridge NSString *)v copy];
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) s = [(__bridge NSNumber *)v stringValue];
    CFRelease(v);
    return s;
}
static NSArray *axChildren(AXUIElementRef el) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &v) != kAXErrorSuccess || !v) return @[];
    NSArray *a = (CFGetTypeID(v) == CFArrayGetTypeID()) ? [(__bridge NSArray *)v copy] : @[];
    CFRelease(v);
    return a;
}
static BOOL axFrame(AXUIElementRef el, CGRect *out) {
    CFTypeRef pos = NULL, size = NULL;
    BOOL ok = NO;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &pos) == kAXErrorSuccess && pos &&
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &size) == kAXErrorSuccess && size) {
        CGPoint p; CGSize s;
        if (AXValueGetValue((AXValueRef)pos, kAXValueCGPointType, &p) &&
            AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &s)) {
            *out = CGRectMake(p.x, p.y, s.width, s.height); ok = YES;
        }
    }
    if (pos) CFRelease(pos);
    if (size) CFRelease(size);
    return ok;
}
static NSArray *axWindows(AXUIElementRef el) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXWindowsAttribute, &v) != kAXErrorSuccess || !v) return @[];
    NSArray *a = (CFGetTypeID(v) == CFArrayGetTypeID()) ? [(__bridge NSArray *)v copy] : @[];
    CFRelease(v);
    return a;
}
static NSString *axRole(AXUIElementRef el) { return axString(el, kAXRoleAttribute); }

/* Children to traverse. Some apps (Firefox) do not list their window under the
 * app's AXChildren, only under AXWindows; AppKit lists it under both. Union them
 * for the app element, deduped with CFEqual (AX element refs are not pointer-
 * stable, so identity must be tested with CFEqual, not by pointer). */
static NSArray *nodeChildren(AXUIElementRef el) {
    NSArray *ch = axChildren(el);
    NSString *r = axRole(el);
    if (![r isEqualToString:@"AXApplication"]) return ch;
    NSArray *wins = axWindows(el);
    if (!wins.count) return ch;
    NSMutableArray *out = [ch mutableCopy];
    for (id e in wins) {
        BOOL dup = NO;
        for (id x in out) if (CFEqual((__bridge CFTypeRef)e, (__bridge CFTypeRef)x)) { dup = YES; break; }
        if (!dup) [out addObject:e];
    }
    return out;
}
static NSString *axLabel(AXUIElementRef el) {
    NSString *t = axString(el, kAXTitleAttribute);       if (t.length) return t;
    NSString *d = axString(el, kAXDescriptionAttribute); if (d.length) return d;
    NSString *v = axString(el, kAXValueAttribute);       if (v.length) return v;
    return axString(el, kAXHelpAttribute);
}
static void axWake(AXUIElementRef app) {
    /* Ask Chromium/Electron/Gecko to build their full a11y tree. We deliberately
     * do NOT set AXEnhancedUserInterface: on native AppKit apps it has side
     * effects (it can move/resize windows and disturb the window a11y tree). */
    AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
}

static pid_t resolvePid(const char *arg) {
    char *end; long n = strtol(arg, &end, 10);
    if (*end == 0 && n > 0) return (pid_t)n;
    NSString *q = [[NSString stringWithUTF8String:arg] lowercaseString];
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
        NSString *name = a.localizedName.lowercaseString ?: @"";
        NSString *bid  = a.bundleIdentifier.lowercaseString ?: @"";
        if ([name containsString:q] || [bid containsString:q]) return a.processIdentifier;
    }
    return 0;
}
static BOOL ensureTrusted(BOOL prompt) {
    if (AXIsProcessTrusted()) return YES;
    if (prompt) AXIsProcessTrustedWithOptions(
        (__bridge CFDictionaryRef)@{ (__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES });
    return NO;
}

/* depth-first search for elements whose label/role contains text */
static void search(AXUIElementRef el, NSString *q, NSMutableArray *hits, int depth) {
    if (depth > 60) return;
    NSString *l = axLabel(el), *r = axRole(el);
    if ((l && [l.lowercaseString containsString:q]) || (r && [r.lowercaseString containsString:q]))
        [hits addObject:(__bridge id)el];
    for (id c in nodeChildren(el)) search((__bridge AXUIElementRef)c, q, hits, depth + 1);
}
static AXUIElementRef mainWindow(AXUIElementRef app) {
    CFTypeRef w = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &w) == kAXErrorSuccess && w)
        return (AXUIElementRef)w;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &w) == kAXErrorSuccess && w)
        return (AXUIElementRef)w;
    CFTypeRef arr = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &arr) == kAXErrorSuccess && arr) {
        AXUIElementRef r = NULL;
        if (CFArrayGetCount(arr) > 0) r = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(arr, 0));
        CFRelease(arr);
        return r;
    }
    return NULL;
}

/* ================================================================= */
/* CGEvent input                                                    */
/* ================================================================= */

static void cgClick(CGPoint p) {
    CGEventRef mv = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
    CGEventRef dn = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, p, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, mv); usleep(20000);
    CGEventPost(kCGHIDEventTap, dn); usleep(30000);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(mv); CFRelease(dn); CFRelease(up);
}
/* Where keyboard events go: 0 posts to the HID tap (the frontmost app gets
 * them); a pid posts straight to that process with CGEventPostToPid, so the app
 * need not be frontmost and the user's own typing is left alone. `target pid`
 * in a session, or UIDRIVE_POST=pid, selects it. */
static pid_t gPostPid = 0;
static void postEvent(CGEventRef e) {
    if (gPostPid) CGEventPostToPid(gPostPid, e);
    else CGEventPost(kCGHIDEventTap, e);
}

/* Shim route: when the app was launched with appshim, `target shim <sock>` (or
 * UIDRIVE_SHIM=<sock>) sends each key event over the shim's socket instead, and
 * the shim hands it to the window in-process. macOS only routes outside key
 * events to the frontmost app and refuses to activate one from the
 * background, so this is the way to type into an app that stays in the
 * background (on the virtual display, say) without taking the user's focus. */
static int gShimFd = -1;
static int shimConnect(const char *path) {
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strlcpy(a.sun_path, path, sizeof a.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return fd;
}
static BOOL shimCommand(const char *line) {
    if (gShimFd < 0) return NO;
    size_t n = strlen(line);
    if (write(gShimFd, line, n) != (ssize_t)n || write(gShimFd, "\n", 1) != 1) return NO;
    char c; char reply[512]; size_t r = 0;          /* one JSON line back */
    while (read(gShimFd, &c, 1) == 1 && c != '\n') if (r < sizeof reply - 1) reply[r++] = c;
    reply[r] = 0;
    if (!strstr(reply, "\"ok\":true")) { fprintf(stderr, "shim: %s -> %s\n", line, reply); return NO; }
    return YES;
}
/* The characters a keyboard would produce: Control makes control characters,
 * so the app's text input does not type the letter of a C- chord. */
static unichar keyChars(CGKeyCode kc, CGEventFlags fl, unichar ch) {
    switch (kc) {
    case 36: return '\r';  case 48: return '\t';  case 49: return ' ';
    case 51: return 0x7f;  case 53: return 0x1b; case 117: return 0xF728;
    case 123: return 0xF702; case 124: return 0xF703; case 125: return 0xF701; case 126: return 0xF700;
    case 115: return 0xF729; case 119: return 0xF72B; case 116: return 0xF72C; case 121: return 0xF72D;
    }
    if ((fl & kCGEventFlagMaskControl) && ch >= '@' && ch < 0x80) return ch & 0x1f;
    return ch;
}
static void shimKey(const char *type, CGKeyCode kc, CGEventFlags fl, unichar ch) {
    char line[128];
    if (ch) snprintf(line, sizeof line, "keyev %s %u %llu u+%04x", type, kc, (unsigned long long)fl, ch);
    else    snprintf(line, sizeof line, "keyev %s %u %llu", type, kc, (unsigned long long)fl);
    shimCommand(line);
}

/* US ANSI virtual key codes, indexed by code. Apps that read -keyCode (games,
 * editors with their own key maps) need the real code, not 0 with a unicode
 * string. */
static CGKeyCode keyCodeForChar(unichar c, BOOL *shift) {
    static const char lower[] = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.\0\0`";
    static const char upper[] = "ASDFHGZXCV\0BQWERYT!@#$^%+(&_*)}OU{IP\0LJ\"K:|<?NM>\0\0~";
    *shift = NO;
    for (int i = 0; i < (int)sizeof lower - 1; i++) {
        if (lower[i] && lower[i] == c) return (CGKeyCode)i;
        if (upper[i] && upper[i] == c) { *shift = YES; return (CGKeyCode)i; }
    }
    if (c == ' ') return 49;
    if (c == '\n' || c == '\r') return 36;
    if (c == '\t') return 48;
    return 0xFFFF;
}
static CGKeyCode keyCodeForName(NSString *n) {
    NSDictionary *m = @{ @"return": @36, @"enter": @36, @"ret": @36, @"tab": @48, @"space": @49,
                         @"spc": @49, @"delete": @51, @"backspace": @51, @"bs": @51,
                         @"del": @117, @"forwarddelete": @117, @"escape": @53, @"esc": @53,
                         @"left": @123, @"right": @124, @"down": @125, @"up": @126,
                         @"home": @115, @"end": @119, @"pageup": @116, @"pagedown": @121,
                         @"pgup": @116, @"pgdn": @121,
                         @"f1": @122, @"f2": @120, @"f3": @99, @"f4": @118, @"f5": @96, @"f6": @97,
                         @"f7": @98, @"f8": @100, @"f9": @101, @"f10": @109, @"f11": @103, @"f12": @111 };
    NSNumber *k = m[n.lowercaseString];
    if (k) return (CGKeyCode)k.intValue;
    if (n.length == 1) { BOOL sh; return keyCodeForChar([n.lowercaseString characterAtIndex:0], &sh); }
    return 0xFFFF;
}
static CGEventFlags parseFlags(NSString *s) {
    CGEventFlags f = 0; if (!s) return 0; s = s.lowercaseString;
    if ([s containsString:@"shift"]) f |= kCGEventFlagMaskShift;
    if ([s containsString:@"ctrl"] || [s containsString:@"control"]) f |= kCGEventFlagMaskControl;
    if ([s containsString:@"alt"] || [s containsString:@"opt"]) f |= kCGEventFlagMaskAlternate;
    if ([s containsString:@"cmd"] || [s containsString:@"command"]) f |= kCGEventFlagMaskCommand;
    return f;
}

/* Modifiers go out as their own key events (flagsChanged), as a keyboard sends
 * them: some apps track Control/Option/Shift from those and ignore the flags on
 * the key event itself. */
static void postModifiers(CGEventFlags fl, BOOL down) {
    static const struct { CGEventFlags mask; CGKeyCode code; } mods[] = {
        { kCGEventFlagMaskControl, 59 }, { kCGEventFlagMaskAlternate, 58 },
        { kCGEventFlagMaskShift, 56 },   { kCGEventFlagMaskCommand, 55 } };
    CGEventFlags held = down ? 0 : fl;
    for (int i = 0; i < 4; i++) {
        int k = down ? i : 3 - i;
        if (!(fl & mods[k].mask)) continue;
        held = down ? (held | mods[k].mask) : (held & ~mods[k].mask);
        if (gShimFd >= 0) { shimKey("flags", mods[k].code, held, 0); continue; }
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, mods[k].code, down);
        CGEventSetType(e, kCGEventFlagsChanged);
        CGEventSetFlags(e, held);
        postEvent(e); usleep(8000);
        CFRelease(e);
    }
}
static void postKeyCode(CGKeyCode kc, CGEventFlags fl, BOOL down, unichar ch) {
    if (gShimFd >= 0) { shimKey(down ? "down" : "up", kc, fl, keyChars(kc, fl, ch)); return; }
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, kc, down);
    CGEventSetFlags(e, fl);
    if (ch) CGEventKeyboardSetUnicodeString(e, 1, &ch);
    postEvent(e);
    CFRelease(e);
}
static void cgTypeString(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        UniChar ch = [s characterAtIndex:i];
        BOOL shift = NO;
        CGKeyCode kc = keyCodeForChar(ch, &shift);
        CGEventFlags fl = shift ? kCGEventFlagMaskShift : 0;
        if (kc == 0xFFFF) kc = 0;              /* not on the keyboard: unicode only */
        if (shift) postModifiers(fl, YES);
        postKeyCode(kc, fl, YES, ch); usleep(6000);
        postKeyCode(kc, fl, NO, ch);  usleep(6000);
        if (shift) postModifiers(fl, NO);
    }
}
/* phase: 1 down only, 2 up only, 3 down, hold_ms, up */
static BOOL cgKeyPhase(NSString *name, CGEventFlags fl, int phase, int hold_ms) {
    CGKeyCode kc = keyCodeForName(name);
    if (kc == 0xFFFF) return NO;
    unichar ch = 0;
    if (name.length == 1) {
        BOOL sh; ch = [name characterAtIndex:0];
        CGKeyCode code = keyCodeForChar(ch, &sh);
        if (sh) fl |= kCGEventFlagMaskShift;
        /* S-' types '"': the character the shifted key makes */
        static const char upper[] = "ASDFHGZXCV\0BQWERYT!@#$^%+(&_*)}OU{IP\0LJ\"K:|<?NM>\0\0~";
        if (!sh && (fl & kCGEventFlagMaskShift) && code < sizeof upper - 1 && upper[code]) ch = upper[code];
    }
    if (phase & 1) { postModifiers(fl, YES); postKeyCode(kc, fl, YES, ch); }
    if (phase == 3) usleep((useconds_t)(hold_ms > 0 ? hold_ms : 20) * 1000);
    if (phase & 2) { postKeyCode(kc, fl, NO, ch); postModifiers(fl, NO); }
    return YES;
}
static BOOL cgKey(NSString *name, NSString *mods) {
    return cgKeyPhase(name, parseFlags(mods), 3, 20);
}
/* Emacs notation: C- Control, M- Option (Meta), S- Shift, s- Command, then one
 * character or a key name (RET TAB SPC ESC BS DEL up down f1 ...): "C-x",
 * "M-x", "C-S-p", "S-p", "RET". An upper-case letter implies Shift. */
static BOOL cgChord(NSString *tok) {
    CGEventFlags fl = 0;
    NSString *k = tok;
    while (k.length > 2 && [k characterAtIndex:1] == '-') {
        unichar m = [k characterAtIndex:0];
        if (m == 'C') fl |= kCGEventFlagMaskControl;
        else if (m == 'M') fl |= kCGEventFlagMaskAlternate;
        else if (m == 'S') fl |= kCGEventFlagMaskShift;
        else if (m == 's') fl |= kCGEventFlagMaskCommand;
        else break;
        k = [k substringFromIndex:2];
    }
    return cgKeyPhase(k, fl, 3, 20);
}

/* ================================================================= */
/* capture (CoreGraphics) -> PNG                                     */
/* ================================================================= */

static BOOL writePNG(CGImageRef img, NSString *path) {
    if (!img) return NO;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (__bridge CFStringRef)path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)@"public.png", 1, NULL);
    BOOL ok = NO;
    if (dst) { CGImageDestinationAddImage(dst, img, NULL); ok = CGImageDestinationFinalize(dst); CFRelease(dst); }
    CFRelease(url);
    return ok;
}
/* ScreenCaptureKit: capture a window by id, or a display by id, to a CGImage.
 * Async API driven synchronously with a semaphore. Needs Screen Recording
 * permission; returns NULL (and the caller reports why) if denied or unmatched. */
static CGImageRef sckCapture(CGWindowID wid, CGDirectDisplayID did) {
    if (@available(macOS 14.0, *)) {
        __block CGImageRef result = NULL;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
            if (!content) { dispatch_semaphore_signal(sem); return; }
            SCContentFilter *filter = nil;
            SCStreamConfiguration *cfg = [SCStreamConfiguration new];
            if (wid) {
                for (SCWindow *w in content.windows) {
                    if (w.windowID == wid) {
                        filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
                        cfg.width  = (size_t)(w.frame.size.width  * 2);
                        cfg.height = (size_t)(w.frame.size.height * 2);
                        break;
                    }
                }
            } else if (did) {
                for (SCDisplay *d in content.displays) {
                    if (d.displayID == did) {
                        filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
                        cfg.width  = (size_t)(d.width  * 2);
                        cfg.height = (size_t)(d.height * 2);
                        break;
                    }
                }
            }
            if (!filter) { dispatch_semaphore_signal(sem); return; }
            [SCScreenshotManager captureImageWithFilter:filter configuration:cfg
                completionHandler:^(CGImageRef img, NSError *e2) {
                    if (img) result = CGImageRetain(img);
                    dispatch_semaphore_signal(sem);
                }];
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)6 * NSEC_PER_SEC));
        return result;
    }
    return NULL;
}

/* frontmost on-screen window id for a pid, via the window server */
static CGWindowID frontWindowForPid(pid_t pid, CGRect *bounds) {
    CFArrayRef wl = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    CGWindowID best = 0; double bestArea = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(wl); i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(wl, i);
        int wpid = 0; CFNumberRef p = CFDictionaryGetValue(w, kCGWindowOwnerPID);
        if (p) CFNumberGetValue(p, kCFNumberIntType, &wpid);
        if (wpid != pid) continue;
        int layer = 0; CFNumberRef L = CFDictionaryGetValue(w, kCGWindowLayer);
        if (L) CFNumberGetValue(L, kCFNumberIntType, &layer);
        if (layer != 0) continue;
        CGRect r; CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r);
        double area = r.size.width * r.size.height;
        if (area > bestArea) {
            bestArea = area;
            CFNumberRef n = CFDictionaryGetValue(w, kCGWindowNumber);
            if (n) CFNumberGetValue(n, kCFNumberIntType, (int *)&best);
            if (bounds) *bounds = r;
        }
    }
    CFRelease(wl);
    return best;
}

/* ================================================================= */
/* virtual display backend (private CGVirtualDisplay, runtime-probed)*/
/* ================================================================= */

/* Returns a retained CGVirtualDisplay object and fills *outDid, or nil on any
 * failure. All private-API use is guarded so a missing/renamed symbol just
 * means "unavailable" and the caller falls back. */
static id makeVirtualDisplay(uint32_t w, uint32_t h, CGDirectDisplayID *outDid) {
    @try {
        Class DescC = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class SetC  = NSClassFromString(@"CGVirtualDisplaySettings");
        Class ModeC = NSClassFromString(@"CGVirtualDisplayMode");
        Class DispC = NSClassFromString(@"CGVirtualDisplay");
        if (!DescC || !SetC || !ModeC || !DispC) return nil;

        id desc = [[DescC alloc] init];
        void (^trySet)(NSString *, id) = ^(NSString *k, id v) {
            @try { [desc setValue:v forKey:k]; } @catch (__unused NSException *e) {}
        };
        trySet(@"name", @"uidrive Virtual Display");
        trySet(@"maxPixelsWide", @(w));
        trySet(@"maxPixelsHigh", @(h));
        trySet(@"sizeInMillimeters", [NSValue valueWithSize:NSMakeSize(w / 4.0, h / 4.0)]);
        trySet(@"productID", @0x1234);
        trySet(@"vendorID", @0x3456);
        trySet(@"serialNum", @0x0001);

        id mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
            [ModeC alloc], sel_registerName("initWithWidth:height:refreshRate:"),
            (NSUInteger)w, (NSUInteger)h, 60.0);
        if (!mode) return nil;

        id settings = [[SetC alloc] init];
        @try { [settings setValue:@0 forKey:@"hiDPI"]; } @catch (__unused NSException *e) {}
        @try { [settings setValue:@[mode] forKey:@"modes"]; } @catch (__unused NSException *e) {}

        id disp = ((id (*)(id, SEL, id))objc_msgSend)(
            [DispC alloc], sel_registerName("initWithDescriptor:"), desc);
        if (!disp) return nil;

        BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(
            disp, sel_registerName("applySettings:"), settings);
        if (!applied) return nil;

        CGDirectDisplayID did = 0;
        @try { did = (CGDirectDisplayID)[[disp valueForKey:@"displayID"] unsignedIntValue]; }
        @catch (__unused NSException *e) { return nil; }
        if (did == 0) return nil;
        if (outDid) *outDid = did;
        return disp;   /* caller retains by holding the reference */
    } @catch (__unused NSException *e) {
        return nil;
    }
}

/* ================================================================= */
/* command handlers, shared by `do` and `session`                   */
/* ================================================================= */

typedef struct {
    pid_t pid;
    AXUIElementRef app;
    BOOL isolated;
    id vdisp;                    /* retained CGVirtualDisplay while isolated */
    CGDirectDisplayID did;
    AXUIElementRef win;          /* window element we moved */
    CGRect savedOrigin;          /* to restore on un-isolate */
    id recorder;                 /* UIRecorder while `record start` runs */
} Ctx;

/* ================================================================= */
/* recording (ScreenCaptureKit -> movie file, macOS 15+)            */
/* ================================================================= */

API_AVAILABLE(macos(15.0))
@interface UIRecorder : NSObject <SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate>
@property (strong) SCContentFilter *filter;
@property (strong) SCStreamConfiguration *cfg;
@property (strong) SCStream *stream;
@property (strong) SCRecordingOutput *output;
@property (strong) dispatch_queue_t queue;
@property (strong) dispatch_semaphore_t done;
@property (strong) NSString *path;          /* the first part; later parts get .N before the extension */
@property (strong) NSMutableArray<NSString *> *parts;
@property BOOL stopping, failed;
- (BOOL)startPart:(NSError **)err;
@end
@implementation UIRecorder
- (NSString *)partPath:(NSUInteger)n {
    if (n == 0) return self.path;
    return [NSString stringWithFormat:@"%@.%lu.%@", self.path.stringByDeletingPathExtension,
            (unsigned long)n, self.path.pathExtension];
}
/* One stream writing one file. A stream can die mid-recording ("Unknown
 * stream error" from ScreenCaptureKit); the delegate then starts the next part
 * so the recording goes on, and `record stop` lists every part. */
- (BOOL)startPart:(NSError **)err {
    NSString *path = [self partPath:self.parts.count];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    SCRecordingOutputConfiguration *rc = [SCRecordingOutputConfiguration new];
    rc.outputURL = [NSURL fileURLWithPath:path];
    rc.outputFileType = [path.pathExtension.lowercaseString isEqualToString:@"mov"]
                      ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4;
    rc.videoCodecType = AVVideoCodecTypeH264;
    self.done = dispatch_semaphore_create(0);
    self.output = [[SCRecordingOutput alloc] initWithConfiguration:rc delegate:self];
    self.stream = [[SCStream alloc] initWithFilter:self.filter configuration:self.cfg delegate:self];
    if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.queue error:err] ||
        ![self.stream addRecordingOutput:self.output error:err]) return NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *startErr = nil;
    [self.stream startCaptureWithCompletionHandler:^(NSError *e) { startErr = e; dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)6 * NSEC_PER_SEC));
    if (startErr) { if (err) *err = startErr; return NO; }
    [self.parts addObject:path];
    return YES;
}
- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)b ofType:(SCStreamOutputType)t {}
- (void)stream:(SCStream *)s didStopWithError:(NSError *)e {
    printf("recording stream stopped (%s); continuing in a new part\n", e.localizedDescription.UTF8String);
    fflush(stdout);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @synchronized (self) {
            if (self.stopping || s != self.stream) return;
            /* let the dead part finish writing its file first */
            dispatch_semaphore_wait(self.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)3 * NSEC_PER_SEC));
            NSError *err = nil;
            if (![self startPart:&err]) {
                fprintf(stderr, "recording could not restart: %s\n", err.localizedDescription.UTF8String);
                self.failed = YES;
            }
        }
    });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)o { if (o == self.output) dispatch_semaphore_signal(self.done); }
- (void)recordingOutput:(SCRecordingOutput *)o didFailWithError:(NSError *)e {
    fprintf(stderr, "recording part failed: %s\n", e.localizedDescription.UTF8String);
    if (o == self.output) dispatch_semaphore_signal(self.done);
}
@end

/* Records the app's front window (wherever it is, the virtual display
 * included) to an .mp4 or .mov until recordStop. */
static int recordStart(Ctx *c, NSString *path, int fps, BOOL wholeDisplay) {
    if (@available(macOS 15.0, *)) {
        if (c->recorder) { fprintf(stderr, "already recording\n"); return 1; }
        CGWindowID wid = frontWindowForPid(c->pid, NULL);
        if (!wid) { fprintf(stderr, "no on-screen window for pid %d\n", c->pid); return 1; }
        __block SCWindow *win = nil;
        __block SCDisplay *disp = nil;
        __block NSMutableArray<SCRunningApplication *> *others = [NSMutableArray array];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
            for (SCWindow *w in content.windows) if (w.windowID == wid) win = w;
            CGPoint mid = win ? CGPointMake(CGRectGetMidX(win.frame), CGRectGetMidY(win.frame)) : CGPointZero;
            for (SCDisplay *d in content.displays) if (CGRectContainsPoint(d.frame, mid)) disp = d;
            for (SCRunningApplication *a in content.applications) if (a.processID != c->pid) [others addObject:a];
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)6 * NSEC_PER_SEC));
        if (!win) { fprintf(stderr, "window %u not capturable (Screen Recording permission?)\n", wid); return 1; }

        UIRecorder *r = [UIRecorder new];
        SCStreamConfiguration *cfg = [SCStreamConfiguration new];
        if (wholeDisplay && disp) {
            /* the display the window is on: costs the app less than a window
             * capture, which holds on to the window's own surfaces and slows
             * its drawing */
            /* this app alone: other apps' windows can land on the same
             * display (a virtual one included) and must not be recorded.
             * Excluding apps keeps the cheap composited path; a window list
             * (includingWindows:) holds the app's surfaces like a window
             * capture does */
            r.filter = [[SCContentFilter alloc] initWithDisplay:disp excludingApplications:others exceptingWindows:@[]];
            /* only the window's content: its frame on the display, less the
             * 32 pt title bar (and the menu bar, if the window is under it) */
            CGRect wf = CGRectOffset(win.frame, -disp.frame.origin.x, -disp.frame.origin.y);
            wf.origin.y += 32; wf.size.height -= 32;
            wf = CGRectIntersection(wf, CGRectMake(0, 0, disp.width, disp.height));
            cfg.sourceRect = wf;
            cfg.width  = ((size_t)wf.size.width) & ~1UL;
            cfg.height = ((size_t)wf.size.height) & ~1UL;
        } else {
            r.filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:win];
            float scale = r.filter.pointPixelScale > 0 ? r.filter.pointPixelScale : 1;
            cfg.width  = ((size_t)(win.frame.size.width  * scale)) & ~1UL;
            cfg.height = ((size_t)(win.frame.size.height * scale)) & ~1UL;
        }
        cfg.minimumFrameInterval = CMTimeMake(1, fps > 0 ? fps : 30);
        cfg.showsCursor = NO;
        cfg.queueDepth = 6;
        r.cfg = cfg;
        r.queue = dispatch_queue_create("uidrive.record", DISPATCH_QUEUE_SERIAL);
        r.path = path;
        r.parts = [NSMutableArray array];
        NSError *e = nil;
        if (![r startPart:&e]) {
            fprintf(stderr, "recording start failed: %s\n", e.localizedDescription.UTF8String);
            return 1;
        }
        c->recorder = r;
        printf("recording %s %u at %zux%zu, %d fps -> %s\n", (wholeDisplay && disp) ? "display" : "window",
               (wholeDisplay && disp) ? disp.displayID : wid, cfg.width, cfg.height, fps > 0 ? fps : 30, path.UTF8String);
        return 0;
    }
    fprintf(stderr, "recording needs macOS 15\n");
    return 1;
}
/* Prints "recorded PATH" and, if the stream had to restart, one
 * "part PATH" line per file in order. */
static int recordStop(Ctx *c) {
    if (@available(macOS 15.0, *)) {
        UIRecorder *r = c->recorder;
        if (!r) { fprintf(stderr, "not recording\n"); return 1; }
        c->recorder = nil;
        @synchronized (r) {
            r.stopping = YES;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [r.stream stopCaptureWithCompletionHandler:^(NSError *err) { dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)10 * NSEC_PER_SEC));
            dispatch_semaphore_wait(r.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)10 * NSEC_PER_SEC));
        }
        printf("%s %s\n", r.failed ? "recording failed:" : "recorded", r.path.UTF8String);
        if (r.parts.count > 1)
            for (NSString *p in r.parts) printf("part %s\n", p.UTF8String);
        return r.failed ? 1 : 0;
    }
    return 1;
}

static void printHit(AXUIElementRef el) {
    NSString *role = axRole(el) ?: @"?";
    NSString *label = axLabel(el) ?: @"";
    CGRect f;
    if (axFrame(el, &f))
        printf("%-20s \"%s\"  @ (%g,%g) %gx%g  center (%g,%g)\n", role.UTF8String, label.UTF8String,
               f.origin.x, f.origin.y, f.size.width, f.size.height,
               f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2);
    else
        printf("%-20s \"%s\"  (no position)\n", role.UTF8String, label.UTF8String);
}
static void dumpTree(AXUIElementRef el, int depth, int maxdepth) {
    NSString *role = axRole(el) ?: @"?", *label = axLabel(el);
    printf("%*s%s%s%s%s\n", depth * 2, "", role.UTF8String,
           label.length ? "  \"" : "", label.length ? label.UTF8String : "", label.length ? "\"" : "");
    if (depth >= maxdepth) return;
    for (id c in nodeChildren(el)) dumpTree((__bridge AXUIElementRef)c, depth + 1, maxdepth);
}
/* Returns a RETAINED element (caller must CFRelease) or NULL. The retain is
 * required: ARC frees the search array when this returns, which would otherwise
 * leave the element dangling. */
static AXUIElementRef firstMatch(Ctx *c, NSString *text) {
    NSMutableArray *hits = [NSMutableArray array];
    search(c->app, text.lowercaseString, hits, 0);
    if (!hits.count) return NULL;
    return (AXUIElementRef)CFRetain((__bridge CFTypeRef)hits[0]);
}

/* ================================================================= */
/* form fields: enumerate + fill without stealing focus             */
/* ================================================================= */

static BOOL isEditableRole(NSString *r) {
    static NSArray *roles;
    if (!roles) roles = @[@"AXTextField", @"AXTextArea", @"AXComboBox",
                          @"AXSearchField", @"AXSecureTextField"];
    return r && [roles containsObject:r];
}

/* The field's visible LABEL (not its content). Web forms expose it via the
 * placeholder or a linked title element; native apps via title/description. */
static NSString *fieldLabel(AXUIElementRef el) {
    NSString *p = axString(el, CFSTR("AXPlaceholderValue")); if (p.length) return p;
    NSString *t = axString(el, kAXTitleAttribute);           if (t.length) return t;
    NSString *d = axString(el, kAXDescriptionAttribute);     if (d.length) return d;
    CFTypeRef le = NULL;                                      /* linked label element */
    if (AXUIElementCopyAttributeValue(el, kAXTitleUIElementAttribute, &le) == kAXErrorSuccess && le) {
        NSString *lt = axLabel((AXUIElementRef)le); CFRelease(le);
        if (lt.length) return lt;
    }
    return axString(el, kAXHelpAttribute) ?: @"";
}

static void collectFields(AXUIElementRef el, NSMutableArray *out, int depth) {
    if (depth > 60) return;
    if (isEditableRole(axRole(el))) [out addObject:(__bridge id)el];
    for (id c in nodeChildren(el)) collectFields((__bridge AXUIElementRef)c, out, depth + 1);
}

/* Find the first editable field whose label contains q (case-insensitive).
 * Returns a borrowed ref into `fs` (keep `fs` alive while using it). */
static AXUIElementRef fieldByLabel(NSArray *fs, NSString *q) {
    NSString *lq = q.lowercaseString;
    for (id e in fs) {
        NSString *l = fieldLabel((__bridge AXUIElementRef)e).lowercaseString;
        if (l.length && [l containsString:lq]) return (__bridge AXUIElementRef)e;
    }
    return NULL;
}

static NSArray<NSString *> *tokenize(NSString *line);
/* returns 0 on success, nonzero on error; prints result */
static int runCmd(Ctx *c, NSArray<NSString *> *a) {
    if (a.count == 0) return 0;
    NSString *cmd = a[0];

    if ([cmd isEqualToString:@"tree"]) {
        dumpTree(c->app, 0, a.count > 1 ? a[1].intValue : 6);
        return 0;
    }
    if ([cmd isEqualToString:@"fields"]) {       /* JSON of every editable field */
        NSMutableArray *fs = [NSMutableArray array];
        collectFields(c->app, fs, 0);
        NSMutableArray *out = [NSMutableArray array];
        int i = 0;
        for (id e in fs) {
            AXUIElementRef el = (__bridge AXUIElementRef)e;
            CGRect f = CGRectZero; axFrame(el, &f);
            [out addObject:@{ @"i": @(i++), @"role": axRole(el) ?: @"?",
                @"label": fieldLabel(el) ?: @"", @"value": axString(el, kAXValueAttribute) ?: @"",
                @"x": @(f.origin.x), @"y": @(f.origin.y), @"w": @(f.size.width), @"h": @(f.size.height),
                @"cx": @(f.origin.x + f.size.width / 2), @"cy": @(f.origin.y + f.size.height / 2) }];
        }
        NSData *j = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(j.bytes, 1, j.length, stdout); printf("\n");
        return 0;
    }
    if ([cmd isEqualToString:@"setval"]) {       /* setval <label-substr> <text>: no focus steal */
        if (a.count < 3) { fprintf(stderr, "usage: setval <label-substr> <text>\n"); return 2; }
        NSMutableArray *fs = [NSMutableArray array];
        collectFields(c->app, fs, 0);
        AXUIElementRef t = fieldByLabel(fs, a[1]);
        if (!t) { printf("no field matching \"%s\"\n", a[1].UTF8String); return 1; }
        AXUIElementSetAttributeValue(t, kAXFocusedAttribute, kCFBooleanTrue);   /* focus, no activate */
        AXError e = AXUIElementSetAttributeValue(t, kAXValueAttribute, (__bridge CFTypeRef)a[2]);
        NSString *rb = axString(t, kAXValueAttribute) ?: @"";
        printf("setval \"%s\" -> %s; value now \"%s\"\n", a[1].UTF8String,
               e == kAXErrorSuccess ? "ok" : "AXError (field may need type fallback)", rb.UTF8String);
        return e == kAXErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqualToString:@"focus"]) {        /* focus <label-substr>: no activate, no mouse */
        if (a.count < 2) { fprintf(stderr, "usage: focus <label-substr>\n"); return 2; }
        NSMutableArray *fs = [NSMutableArray array];
        collectFields(c->app, fs, 0);
        AXUIElementRef t = fieldByLabel(fs, a[1]);
        if (!t) { printf("no field matching \"%s\"\n", a[1].UTF8String); return 1; }
        AXError e = AXUIElementSetAttributeValue(t, kAXFocusedAttribute, kCFBooleanTrue);
        printf("focus \"%s\" -> %s\n", a[1].UTF8String, e == kAXErrorSuccess ? "ok" : "AXError");
        return e == kAXErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqualToString:@"find"]) {
        if (a.count < 2) { fprintf(stderr, "usage: find <text>\n"); return 2; }
        NSMutableArray *hits = [NSMutableArray array];
        search(c->app, a[1].lowercaseString, hits, 0);
        if (!hits.count) { printf("no match\n"); return 1; }
        printf("%lu match(es):\n", (unsigned long)hits.count);
        for (id h in hits) printHit((__bridge AXUIElementRef)h);
        return 0;
    }
    if ([cmd isEqualToString:@"press"]) {
        if (a.count < 2) { fprintf(stderr, "usage: press <text>\n"); return 2; }
        AXUIElementRef t = firstMatch(c, a[1]);
        if (!t) { printf("no match\n"); return 1; }
        printf("target: "); printHit(t);
        AXError e = AXUIElementPerformAction(t, kAXPressAction);
        CFRelease(t);
        printf("AXPress -> %s\n", e == kAXErrorSuccess ? "ok" : "failed");
        return e == kAXErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqualToString:@"click"]) {
        if (a.count < 2) { fprintf(stderr, "usage: click <text>\n"); return 2; }
        AXUIElementRef t = firstMatch(c, a[1]);
        if (!t) { printf("no match\n"); return 1; }
        printf("target: "); printHit(t);
        CGRect f;
        if (axFrame(t, &f)) {                       /* primary: real CGEvent click */
            CFRelease(t);
            [[NSRunningApplication runningApplicationWithProcessIdentifier:c->pid]
                activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            usleep(120000);
            CGPoint ctr = CGPointMake(f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2);
            cgClick(ctr);
            printf("clicked (%g,%g) via CGEvent\n", ctr.x, ctr.y);
            return 0;
        }
        AXError e = AXUIElementPerformAction(t, kAXPressAction);   /* fallback: AXPress */
        CFRelease(t);
        printf("no rect; fell back to AXPress -> %s\n", e == kAXErrorSuccess ? "ok" : "failed");
        return e == kAXErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqualToString:@"type"]) {
        if (a.count < 2) { fprintf(stderr, "usage: type <text>\n"); return 2; }
        cgTypeString(a[1]);
        printf("typed %lu chars\n", (unsigned long)a[1].length);
        return 0;
    }
    if ([cmd isEqualToString:@"key"]) {
        if (a.count < 2) { fprintf(stderr, "usage: key <name> [mods]\n"); return 2; }
        BOOL ok = cgKey(a[1], a.count > 2 ? a[2] : nil);
        printf("key %s -> %s\n", a[1].UTF8String, ok ? "ok" : "unknown key");
        return ok ? 0 : 1;
    }
    if ([cmd isEqualToString:@"keys"]) {            /* keys C-x S-p RET ... */
        if (a.count < 2) { fprintf(stderr, "usage: keys <chord>...  e.g. keys C-x C-f\n"); return 2; }
        for (NSUInteger i = 1; i < a.count; i++) {
            if (!cgChord(a[i])) { printf("unknown key %s\n", a[i].UTF8String); return 1; }
            usleep(60000);
        }
        printf("keys ok\n");
        return 0;
    }
    if ([cmd isEqualToString:@"keydown"] || [cmd isEqualToString:@"keyup"] || [cmd isEqualToString:@"hold"]) {
        BOOL hold = [cmd isEqualToString:@"hold"];
        if (a.count < (hold ? 3 : 2)) {
            fprintf(stderr, "usage: keydown|keyup <name> [mods] | hold <name> <ms> [mods]\n"); return 2;
        }
        NSString *mods = a.count > (hold ? 3 : 2) ? a[hold ? 3 : 2] : nil;
        int phase = hold ? 3 : [cmd isEqualToString:@"keydown"] ? 1 : 2;
        BOOL ok = cgKeyPhase(a[1], parseFlags(mods), phase, hold ? a[2].intValue : 0);
        printf("%s %s -> %s\n", cmd.UTF8String, a[1].UTF8String, ok ? "ok" : "unknown key");
        return ok ? 0 : 1;
    }
    if ([cmd isEqualToString:@"keyscript"]) {       /* keyscript <file>: "ms down|up key" per line */
        if (a.count < 2) { fprintf(stderr, "usage: keyscript <file>  (lines: <ms> down|up <key>)\n"); return 2; }
        NSString *text = [NSString stringWithContentsOfFile:a[1] encoding:NSUTF8StringEncoding error:nil];
        if (!text) { fprintf(stderr, "cannot read %s\n", a[1].UTF8String); return 1; }
        /* timed from one start so the offsets hold however long each event takes */
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        int n = 0;
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *f = tokenize(line);
            if (f.count < 3 || [f[0] hasPrefix:@"#"]) continue;
            double due = t0 + f[0].doubleValue / 1000.0;
            double wait = due - CFAbsoluteTimeGetCurrent();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
            if (!cgKeyPhase(f[2], 0, [f[1] isEqualToString:@"down"] ? 1 : 2, 0)) {
                printf("unknown key %s\n", f[2].UTF8String); return 1;
            }
            n++;
        }
        printf("keyscript: %d events in %.2f s\n", n, CFAbsoluteTimeGetCurrent() - t0);
        return 0;
    }
    if ([cmd isEqualToString:@"activate"]) {        /* bring the app forward: key events need a key window */
        BOOL ok = [[NSRunningApplication runningApplicationWithProcessIdentifier:c->pid]
                      activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        AXUIElementRef w = mainWindow(c->app);
        if (w) {
            AXUIElementSetAttributeValue(w, kAXMainAttribute, kCFBooleanTrue);
            AXUIElementPerformAction(w, kAXRaiseAction);
            CFRelease(w);
        }
        usleep(150000);
        printf("activate -> %s\n", ok ? "ok" : "failed");
        return ok ? 0 : 1;
    }
    if ([cmd isEqualToString:@"sleep"]) {           /* sleep <ms>, for scripts */
        if (a.count < 2) { fprintf(stderr, "usage: sleep <ms>\n"); return 2; }
        usleep((useconds_t)a[1].intValue * 1000);
        printf("slept\n");
        return 0;
    }
    if ([cmd isEqualToString:@"resize"]) {          /* resize <w> <h>, the main window */
        if (a.count < 3) { fprintf(stderr, "usage: resize <w> <h>\n"); return 2; }
        AXUIElementRef w = mainWindow(c->app);
        if (!w) { fprintf(stderr, "no window\n"); return 1; }
        CGSize sz = CGSizeMake(a[1].doubleValue, a[2].doubleValue);
        AXValueRef v = AXValueCreate(kAXValueCGSizeType, &sz);
        AXError e = AXUIElementSetAttributeValue(w, kAXSizeAttribute, v);
        if (v) CFRelease(v);
        CGRect f = CGRectZero;
        if (c->isolated) f.origin = CGPointMake(CGDisplayBounds(c->did).origin.x + 40, CGDisplayBounds(c->did).origin.y + 40);
        else axFrame(w, &f);
        if (gShimFd >= 0) {                          /* outside resizes can be ignored */
            char line[160];
            snprintf(line, sizeof line, "setframe key %g %g %g %g", f.origin.x, f.origin.y, sz.width, sz.height);
            if (shimCommand(line)) e = kAXErrorSuccess;
        }
        CFRelease(w);
        printf("resize -> %s\n", e == kAXErrorSuccess ? "ok" : "failed");
        return e == kAXErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqualToString:@"record"]) {          /* record start <file.mp4> [fps] | record stop */
        if (a.count >= 3 && [a[1] isEqualToString:@"start"])
            return recordStart(c, a[2], a.count > 3 ? a[3].intValue : 30,
                               a.count > 4 && [a[4] isEqualToString:@"display"]);
        if (a.count >= 2 && [a[1] isEqualToString:@"stop"]) return recordStop(c);
        fprintf(stderr, "usage: record start <file.mp4|.mov> [fps] [display] | record stop\n");
        return 2;
    }
    if ([cmd isEqualToString:@"capture"]) {
        if (a.count < 2) { fprintf(stderr, "usage: capture <file.png>\n"); return 2; }
        CGImageRef img = NULL;
        if (c->isolated && c->did) {                 /* capture the virtual display */
            img = sckCapture(0, c->did);
            if (!img) printf("(virtual display capture returned nil; trying window)\n");
        }
        if (!img) {                                   /* capture the on-screen window */
            CGWindowID wid = frontWindowForPid(c->pid, NULL);
            if (!wid) {                                /* fall back to the AX window id */
                AXUIElementRef w = mainWindow(c->app);
                if (w) { _AXUIElementGetWindow(w, &wid); CFRelease(w); }
            }
            if (!wid) { fprintf(stderr, "no window found for pid %d\n", c->pid); return 1; }
            img = sckCapture(wid, 0);
        }
        if (!img) { fprintf(stderr, "capture failed (grant Screen Recording in System Settings "
                                    "> Privacy & Security, or no matching window)\n"); return 1; }
        BOOL ok = writePNG(img, a[1]);
        size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
        CGImageRelease(img);
        if (!ok) { fprintf(stderr, "could not write %s\n", a[1].UTF8String); return 1; }
        printf("captured %zux%zu -> %s\n", w, h, a[1].UTF8String);
        return 0;
    }
    fprintf(stderr, "unknown command: %s\n", cmd.UTF8String);
    return 2;
}


/* ================================================================= */
/* isolate / un-isolate (virtual-display backend)                   */
/* ================================================================= */

static void isolateOn(Ctx *c) {
    if (c->isolated) { printf("already isolated on display %u\n", c->did); return; }
    CGDirectDisplayID did = 0;
    id vd = makeVirtualDisplay(1920, 1200, &did);
    if (!vd) {
        printf("virtual display unavailable on this system; staying on the real screen "
               "(driving and capture still work)\n");
        return;
    }
    c->vdisp = vd; c->did = did; c->isolated = YES;
    CGRect vb = CGDisplayBounds(did);
    AXUIElementRef win = mainWindow(c->app);
    if (win) {
        c->win = win;
        CGRect f; if (axFrame(win, &f)) c->savedOrigin = f;
        CGPoint dst = CGPointMake(vb.origin.x + 40, vb.origin.y + 40);
        AXValueRef pv = AXValueCreate(kAXValueCGPointType, &dst);
        AXUIElementSetAttributeValue(win, kAXPositionAttribute, pv);
        if (pv) CFRelease(pv);
        /* some apps ignore an outside move; through the shim it always lands */
        CGRect f2 = c->savedOrigin;
        (void)f2;
        if (gShimFd >= 0) {
            char line[160];
            snprintf(line, sizeof line, "setframe key %g %g %g %g", dst.x, dst.y,
                     c->savedOrigin.size.width, c->savedOrigin.size.height);
            shimCommand(line);
        }
    }
    printf("isolated on virtual display %u at (%g,%g) %gx%g\n",
           did, vb.origin.x, vb.origin.y, vb.size.width, vb.size.height);
}
static void isolateOff(Ctx *c) {
    if (!c->isolated) { printf("not isolated\n"); return; }
    if (c->win) {                                    /* move the window back */
        CGPoint o = c->savedOrigin.origin;
        AXValueRef pv = AXValueCreate(kAXValueCGPointType, &o);
        AXUIElementSetAttributeValue(c->win, kAXPositionAttribute, pv);
        if (pv) CFRelease(pv);
        if (gShimFd >= 0) {
            CGRect now;
            char line[160];
            if (axFrame(c->win, &now)) {
                snprintf(line, sizeof line, "setframe key %g %g %g %g", o.x, o.y, now.size.width, now.size.height);
                shimCommand(line);
            }
        }
        CFRelease(c->win); c->win = NULL;
    }
    c->vdisp = nil;   /* releasing the CGVirtualDisplay tears the display down */
    c->isolated = NO; c->did = 0;
    printf("un-isolated; virtual display torn down\n");
}

/* ================================================================= */
/* info                                                             */
/* ================================================================= */

static void cmdInfo(Ctx *c) {
    printf("pid:                %d\n", c->pid);
    printf("accessibility:      %s\n", AXIsProcessTrusted() ? "trusted" : "NOT trusted");
    AXUIElementRef w = mainWindow(c->app);
    if (w) {
        printf("main window:        \"%s\"\n", (axString(w, kAXTitleAttribute) ?: @"(untitled)").UTF8String);
        CGWindowID wid = 0;
        if (_AXUIElementGetWindow(w, &wid) == kAXErrorSuccess) printf("window id:          %u\n", wid);
        CFRelease(w);
    } else {
        printf("main window:        none (app has no open window)\n");
    }
    CGWindowID fw = frontWindowForPid(c->pid, NULL);
    printf("on-screen capture:  %s\n", fw ? "available (standard backend)" : "no on-screen window");
    /* Report the virtual-display backend by class presence only -- do NOT create
     * a display here. Creating and immediately tearing one down is both invasive
     * (flashes a display) and crash-prone, and a live session already holds one. */
    if (c->isolated)
        printf("virtual display:    ACTIVE on display %u (vdisplay backend)\n", c->did);
    else {
        BOOL present = NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor");
        printf("virtual display:    %s\n", present ? "available (use `session --isolate`)" : "unavailable (will fall back)");
    }
}

/* ================================================================= */
/* main                                                             */
/* ================================================================= */

static NSArray<NSString *> *tokenize(NSString *line) {
    NSMutableArray *out = [NSMutableArray array];
    NSScanner *sc = [NSScanner scannerWithString:line];
    sc.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];
    while (!sc.atEnd) {
        NSString *tok = nil;
        if ([sc scanString:@"\"" intoString:NULL]) {           /* "quoted token" */
            [sc scanUpToString:@"\"" intoString:&tok];
            [sc scanString:@"\"" intoString:NULL];
        } else {
            [sc scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&tok];
        }
        if (tok) [out addObject:tok];
    }
    return out;
}

static int session(Ctx *c, BOOL startIsolated) {
    if (startIsolated) isolateOn(c);
    printf("uidrive session on pid %d. commands: tree find press click type key capture "
           "isolate quit. ^D to exit.\n> ", c->pid);
    fflush(stdout);
    char buf[8192];
    while (fgets(buf, sizeof buf, stdin)) {
        NSString *line = [[NSString stringWithUTF8String:buf]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray<NSString *> *a = tokenize(line);
        if (a.count) {
            NSString *cmd = a[0];
            if ([cmd isEqualToString:@"quit"] || [cmd isEqualToString:@"exit"]) break;
            else if ([cmd isEqualToString:@"help"])
                printf("tree [d] | find <t> | press <t> | click <t> | type <t> | key <n> [mods] | "
                       "keys <chord>... | keydown|keyup <n> [mods] | hold <n> <ms> [mods] | keyscript <f> | sleep <ms> | "
                       "activate | resize <w> <h> | capture <f.png> | record start <f.mp4> [fps] | record stop | "
                       "target pid|hid|shim <sock> | isolate on|off | info | quit\n");
            else if ([cmd isEqualToString:@"info"]) cmdInfo(c);
            else if ([cmd isEqualToString:@"target"]) {
                if (gShimFd >= 0) { close(gShimFd); gShimFd = -1; }
                gPostPid = (a.count > 1 && [a[1] isEqualToString:@"pid"]) ? c->pid : 0;
                if (a.count > 2 && [a[1] isEqualToString:@"shim"]) {
                    gShimFd = shimConnect(a[2].UTF8String);
                    if (gShimFd < 0) printf("cannot connect to %s\n", a[2].UTF8String);
                }
                printf("keys go to %s\n", gShimFd >= 0 ? "the app through appshim" :
                       gPostPid ? "the process (CGEventPostToPid)" : "the HID tap (frontmost app)");
            }
            else if ([cmd isEqualToString:@"isolate"]) {
                if (a.count > 1 && [a[1] isEqualToString:@"off"]) isolateOff(c);
                else isolateOn(c);
            } else runCmd(c, a);
        }
        printf("> "); fflush(stdout);
    }
    if (c->recorder) recordStop(c);
    if (c->isolated) isolateOff(c);
    printf("bye\n");
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "usage:\n"
                "  uidrive trust\n"
                "  uidrive info <pid|app>\n"
                "  uidrive do <pid|app> <cmd> [args]\n"
                "  uidrive session <pid|app> [--isolate]\n"
                "  uidrive display [w h]     hold a virtual display until stdin closes\n"
                "cmds: tree find press click type key capture\n");
            return 2;
        }
        NSString *verb = [NSString stringWithUTF8String:argv[1]];

        if ([verb isEqualToString:@"display"]) {
            /* uidrive display [w h]: hold a virtual display until stdin closes,
             * for an app to open its window on (appshim's APPSHIM_PLACE) */
            uint32_t w = argc > 3 ? (uint32_t)atoi(argv[2]) : 1920, h = argc > 3 ? (uint32_t)atoi(argv[3]) : 1200;
            CGDirectDisplayID did = 0;
            id vd = makeVirtualDisplay(w, h, &did);
            if (!vd) { fprintf(stderr, "virtual display unavailable\n"); return 1; }
            usleep(500000);
            CGRect b = CGDisplayBounds(did);
            printf("display %u at %g,%g %gx%g\n", did, b.origin.x, b.origin.y, b.size.width, b.size.height);
            fflush(stdout);
            char buf[256];
            while (fgets(buf, sizeof buf, stdin)) {}
            vd = nil;
            printf("display %u torn down\n", did);
            return 0;
        }
        if ([verb isEqualToString:@"trust"]) {
            BOOL t = ensureTrusted(YES);
            printf("accessibility trusted: %s\n", t ? "yes" :
                   "NO (enable this process in System Settings > Privacy & Security > Accessibility)");
            return t ? 0 : 1;
        }
        if (argc < 3) { fprintf(stderr, "uidrive: '%s' needs <pid|app>\n", argv[1]); return 2; }
        if (!ensureTrusted(YES)) {
            fprintf(stderr, "uidrive: not trusted for Accessibility. Enable it in System Settings "
                            "> Privacy & Security > Accessibility and retry.\n");
            return 1;
        }
        pid_t pid = resolvePid(argv[2]);
        if (!pid) { fprintf(stderr, "uidrive: no running app matches '%s'\n", argv[2]); return 1; }

        Ctx c = {0};
        c.pid = pid;
        c.app = AXUIElementCreateApplication(pid);
        const char *post = getenv("UIDRIVE_POST");
        if (post && !strcmp(post, "pid")) gPostPid = pid;
        const char *shim = getenv("UIDRIVE_SHIM");
        if (shim && *shim && (gShimFd = shimConnect(shim)) < 0) {
            fprintf(stderr, "uidrive: cannot connect to the appshim socket %s\n", shim); return 1;
        }
        AXUIElementSetMessagingTimeout(c.app, 3.0f);
        axWake(c.app);
        usleep(900000);   /* give Gecko/Chromium time to (re)build their a11y tree */

        if ([verb isEqualToString:@"info"])    { cmdInfo(&c); return 0; }
        if ([verb isEqualToString:@"session"]) {
            BOOL iso = (argc > 3 && !strcmp(argv[3], "--isolate"));
            return session(&c, iso);
        }
        if ([verb isEqualToString:@"do"]) {
            if (argc < 4) { fprintf(stderr, "uidrive do <pid|app> <cmd> [args]\n"); return 2; }
            NSMutableArray *a = [NSMutableArray array];
            for (int i = 3; i < argc; i++) [a addObject:[NSString stringWithUTF8String:argv[i]]];
            return runCmd(&c, a);
        }
        fprintf(stderr, "uidrive: unknown verb '%s'\n", argv[1]);
        return 2;
    }
}
