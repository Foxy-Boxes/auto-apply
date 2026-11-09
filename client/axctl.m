/*
 * axctl.m -- out-of-process UI scripting via the macOS Accessibility API.
 *
 * When DYLD injection is blocked (hardened-runtime apps like Firefox), this is
 * the supported way to locate and drive another app's UI. It reads the target's
 * accessibility tree with AXUIElement, finds an element by text, reports its
 * on-screen rectangle, and clicks it -- either by AXPress (clean, in-app) or by
 * posting a real CGEvent mouse click at the element's center.
 *
 * Requires the Accessibility permission for whatever process runs this
 * (System Settings > Privacy & Security > Accessibility). Run `axctl trust`
 * to check and trigger the prompt.
 *
 * Usage:
 *   axctl trust
 *   axctl apps
 *   axctl tree  <pid|app> [maxdepth]
 *   axctl find  <pid|app> <text>
 *   axctl press <pid|app> <text>          # AXPress the first match
 *   axctl click <pid|app> <text>          # CGEvent click at the match's center
 *   axctl clickxy <x> <y>                 # click absolute screen coords
 *
 * <app> is matched against the running app's localized name or bundle id
 * (case-insensitive substring); a numeric argument is treated as a pid.
 */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

/* ---- small helpers over the AX C API ---- */

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
/* element's screen rect (top-left origin, same convention CGEvent uses) */
static BOOL axFrame(AXUIElementRef el, CGRect *out) {
    CFTypeRef pos = NULL, size = NULL;
    BOOL ok = NO;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &pos) == kAXErrorSuccess && pos &&
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &size) == kAXErrorSuccess && size) {
        CGPoint p; CGSize s;
        if (AXValueGetValue((AXValueRef)pos, kAXValueCGPointType, &p) &&
            AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &s)) {
            *out = CGRectMake(p.x, p.y, s.width, s.height);
            ok = YES;
        }
    }
    if (pos) CFRelease(pos);
    if (size) CFRelease(size);
    return ok;
}
static NSString *axRole(AXUIElementRef el)  { return axString(el, kAXRoleAttribute); }
static NSString *axTitle(AXUIElementRef el) { return axString(el, kAXTitleAttribute); }

/* the text we search/display for an element: title, description, value, help */
static NSString *axLabel(AXUIElementRef el) {
    NSString *t = axTitle(el);
    if (t.length) return t;
    NSString *d = axString(el, kAXDescriptionAttribute);
    if (d.length) return d;
    NSString *v = axString(el, kAXValueAttribute);
    if (v.length) return v;
    return axString(el, kAXHelpAttribute);
}

/* ---- app resolution ---- */

static pid_t resolvePid(const char *arg) {
    /* pure number -> pid */
    char *end;
    long n = strtol(arg, &end, 10);
    if (*end == 0 && n > 0) return (pid_t)n;
    NSString *q = [[NSString stringWithUTF8String:arg] lowercaseString];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        NSString *name = app.localizedName.lowercaseString ?: @"";
        NSString *bid  = app.bundleIdentifier.lowercaseString ?: @"";
        if ([name containsString:q] || [bid containsString:q]) return app.processIdentifier;
    }
    return 0;
}
static NSRunningApplication *appForPid(pid_t pid) {
    return [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
}

/* ---- trust ---- */

static BOOL ensureTrusted(BOOL prompt) {
    if (AXIsProcessTrusted()) return YES;
    if (prompt) {
        NSDictionary *opts = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES };
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    }
    return NO;
}

/* ---- tree walk ---- */

static void dumpTree(AXUIElementRef el, int depth, int maxdepth) {
    NSString *role = axRole(el) ?: @"?";
    NSString *label = axLabel(el);
    CGRect f;
    char rectbuf[64] = "";
    if (axFrame(el, &f)) snprintf(rectbuf, sizeof rectbuf, "  [%g,%g %gx%g]", f.origin.x, f.origin.y, f.size.width, f.size.height);
    printf("%*s%s%s%s%s\n", depth * 2, "", role.UTF8String,
           label.length ? "  \"" : "", label.length ? label.UTF8String : "",
           label.length ? "\"" : "");
    if (rectbuf[0]) printf("%*s%s\n", depth * 2 + 2, "", rectbuf + 2);
    if (depth >= maxdepth) return;
    for (id c in axChildren(el)) dumpTree((__bridge AXUIElementRef)c, depth + 1, maxdepth);
}

/* ---- search: collect elements whose label/role contains text ---- */

static void search(AXUIElementRef el, NSString *q, NSMutableArray *hits, int depth) {
    if (depth > 60) return;
    NSString *label = axLabel(el);
    NSString *role  = axRole(el);
    if ((label && [label.lowercaseString containsString:q]) ||
        (role  && [role.lowercaseString  containsString:q])) {
        [hits addObject:(__bridge id)el];
    }
    for (id c in axChildren(el)) search((__bridge AXUIElementRef)c, q, hits, depth + 1);
}

static void printHit(AXUIElementRef el) {
    NSString *role = axRole(el) ?: @"?";
    NSString *label = axLabel(el) ?: @"";
    CGRect f = CGRectZero;
    BOOL hasF = axFrame(el, &f);
    if (hasF)
        printf("%-22s \"%s\"  @ (%g,%g) size %gx%g  center (%g,%g)\n",
               role.UTF8String, label.UTF8String,
               f.origin.x, f.origin.y, f.size.width, f.size.height,
               f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2);
    else
        printf("%-22s \"%s\"  (no position)\n", role.UTF8String, label.UTF8String);
}

/* ---- synthetic click via CGEvent at a global (top-left origin) point ---- */

static void cgClick(CGPoint p) {
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, p, kCGMouseButtonLeft);
    CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, move);
    usleep(20000);
    CGEventPost(kCGHIDEventTap, down);
    usleep(30000);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(move); CFRelease(down); CFRelease(up);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: axctl {trust|apps|tree|find|press|click|clickxy} ...\n");
            return 2;
        }
        const char *cmd = argv[1];

        if (!strcmp(cmd, "trust")) {
            BOOL t = ensureTrusted(YES);
            printf("accessibility trusted: %s\n", t ? "yes" : "NO (enable this process in System Settings > Privacy & Security > Accessibility, then retry)");
            return t ? 0 : 1;
        }
        if (!strcmp(cmd, "apps")) {
            for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
                if (a.activationPolicy != NSApplicationActivationPolicyRegular) continue;
                printf("%6d  %-30s %s\n", a.processIdentifier,
                       (a.localizedName ?: @"?").UTF8String,
                       (a.bundleIdentifier ?: @"").UTF8String);
            }
            return 0;
        }
        if (!strcmp(cmd, "clickxy")) {
            if (argc < 4) { fprintf(stderr, "usage: axctl clickxy <x> <y>\n"); return 2; }
            if (!ensureTrusted(YES)) { fprintf(stderr, "axctl: not trusted for Accessibility\n"); return 1; }
            cgClick(CGPointMake(atof(argv[2]), atof(argv[3])));
            printf("clicked (%s,%s)\n", argv[2], argv[3]);
            return 0;
        }

        /* remaining commands take <pid|app> */
        if (argc < 3) { fprintf(stderr, "usage: axctl %s <pid|app> ...\n", cmd); return 2; }
        if (!ensureTrusted(YES)) {
            fprintf(stderr, "axctl: this process is not trusted for Accessibility.\n"
                            "       Enable it in System Settings > Privacy & Security > Accessibility and retry.\n");
            return 1;
        }
        pid_t pid = resolvePid(argv[2]);
        if (!pid) { fprintf(stderr, "axctl: no running app matches '%s'\n", argv[2]); return 1; }
        AXUIElementRef appEl = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(appEl, 2.0f);

        /* Gecko/Chromium/Electron apps keep their full a11y tree switched off
         * until an assistive client asks for it. Setting these attributes is
         * the request. Harmless on native apps that ignore them. Give the app
         * a moment to build the tree before we walk it. */
        AXUIElementSetAttributeValue(appEl, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
        AXUIElementSetAttributeValue(appEl, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
        usleep(400000);

        if (!strcmp(cmd, "tree")) {
            int maxdepth = argc > 3 ? atoi(argv[3]) : 6;
            dumpTree(appEl, 0, maxdepth);
            return 0;
        }
        if (!strcmp(cmd, "find") || !strcmp(cmd, "press") || !strcmp(cmd, "click")) {
            if (argc < 4) { fprintf(stderr, "usage: axctl %s <pid|app> <text>\n", cmd); return 2; }
            NSString *q = [[NSString stringWithUTF8String:argv[3]] lowercaseString];
            NSMutableArray *hits = [NSMutableArray array];
            search(appEl, q, hits, 0);
            if (hits.count == 0) { fprintf(stderr, "axctl: no element matches '%s'\n", argv[3]); return 1; }

            if (!strcmp(cmd, "find")) {
                printf("%lu match(es):\n", (unsigned long)hits.count);
                for (id h in hits) printHit((__bridge AXUIElementRef)h);
                return 0;
            }
            AXUIElementRef target = (__bridge AXUIElementRef)hits[0];
            printf("target: "); printHit(target);

            if (!strcmp(cmd, "press")) {
                AXError e = AXUIElementPerformAction(target, kAXPressAction);
                printf("AXPress -> %s\n", e == kAXErrorSuccess ? "ok" : "failed");
                return e == kAXErrorSuccess ? 0 : 1;
            }
            /* click: bring app forward, then post a real click at the center */
            CGRect f;
            if (!axFrame(target, &f)) { fprintf(stderr, "axctl: match has no screen position\n"); return 1; }
            [appForPid(pid) activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            usleep(150000);
            CGPoint c = CGPointMake(f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2);
            cgClick(c);
            printf("clicked center (%g,%g)\n", c.x, c.y);
            return 0;
        }
        fprintf(stderr, "axctl: unknown command '%s'\n", cmd);
        return 2;
    }
}
