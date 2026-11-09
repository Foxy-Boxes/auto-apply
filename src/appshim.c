/*
 * appshim.c -- AppKit scripting shim, injected with DYLD_INSERT_LIBRARIES.
 *
 * A UI-automation / test-harness layer. Written in plain C against the
 * Objective-C runtime (no AppKit headers, no ObjC syntax) so it can be built
 * with a C compiler and preloaded into a Cocoa app you launch yourself.
 *
 * On load it:
 *   - hooks  -[NSApplication sendEvent:]           (observes every input event)
 *   - hooks  -[NSApplication sendAction:to:from:]  (observes target/action dispatch)
 *   - opens a Unix domain socket ($APPSHIM_SOCK or /tmp/appshim-<pid>.sock)
 *
 * Protocol: a client connects and sends one text command per line; the shim
 * replies with one JSON object per line. A client that sends "watch" also
 * receives an asynchronous JSON line for each observed event/action.
 *
 * All AppKit access is marshalled onto the main thread via dispatch_sync_f,
 * so the socket server thread never touches UI state directly.
 */
#define _DARWIN_C_SOURCE
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>

extern void *objc_autoreleasePoolPush(void);
extern void  objc_autoreleasePoolPop(void *);

/* CGStructs over 16 bytes come back via the stret variant on x86_64; on
 * arm64 the normal objc_msgSend returns them. */
#if defined(__x86_64__)
#  define MSGSEND_STRET ((void *)objc_msgSend_stret)
#else
#  define MSGSEND_STRET ((void *)objc_msgSend)
#endif

/* ------------------------------------------------------------------ */
/* objc_msgSend thin wrappers                                          */
/* ------------------------------------------------------------------ */

typedef id             (*f_id)(id, SEL);
typedef id             (*f_id_id)(id, SEL, id);
typedef id             (*f_id_long)(id, SEL, long);
typedef id             (*f_id_point)(id, SEL, CGPoint);
typedef BOOL           (*f_bool)(id, SEL);
typedef BOOL           (*f_bool_id)(id, SEL, id);
typedef BOOL           (*f_bool_sel)(id, SEL, SEL);
typedef BOOL           (*f_bool_sel_id_id)(id, SEL, SEL, id, id);
typedef long           (*f_long)(id, SEL);
typedef unsigned long  (*f_ulong)(id, SEL);
typedef unsigned short (*f_ushort)(id, SEL);
typedef double         (*f_double)(id, SEL);
typedef void           (*f_void)(id, SEL);
typedef void           (*f_void_id)(id, SEL, id);
typedef void           (*f_void_long)(id, SEL, long);
typedef void           (*f_void_id_bool)(id, SEL, id, BOOL);
typedef const char    *(*f_cstr)(id, SEL);
typedef SEL            (*f_sel)(id, SEL);
typedef Class          (*f_class)(id, SEL);
typedef CGRect         (*f_rect)(id, SEL);
typedef CGRect         (*f_rect_rect_id)(id, SEL, CGRect, id);
typedef CGPoint        (*f_point)(id, SEL);
typedef id             (*f_id_rect)(id, SEL, CGRect);
typedef void           (*f_void_rect_id)(id, SEL, CGRect, id);
typedef BOOL           (*f_bool_id_bool)(id, SEL, id, BOOL);
typedef id (*f_mouseEvent)(id, SEL, unsigned long type, CGPoint loc, unsigned long mods,
                           double ts, long winnum, id ctx, long evnum, long clicks, float pressure);
typedef id (*f_keyEvent)(id, SEL, unsigned long type, CGPoint loc, unsigned long mods,
                         double ts, long winnum, id ctx, id chars, id charsIgn, BOOL rep,
                         unsigned short keycode);

#define SEL_(s) sel_registerName(s)
#define CLS(n)  ((id)objc_getClass(n))

static id     msg(id o, const char *s)              { return ((f_id)objc_msgSend)(o, SEL_(s)); }
static id     msg_long(id o, const char *s, long a) { return ((f_id_long)objc_msgSend)(o, SEL_(s), a); }
static BOOL   msgb(id o, const char *s)             { return ((f_bool)objc_msgSend)(o, SEL_(s)); }
static long   msgl(id o, const char *s)             { return ((f_long)objc_msgSend)(o, SEL_(s)); }
static void   msgv_id(id o, const char *s, id a)    { ((f_void_id)objc_msgSend)(o, SEL_(s), a); }
static CGRect msgrect(id o, const char *s)          { return ((f_rect)MSGSEND_STRET)(o, SEL_(s)); }

static BOOL responds(id o, const char *s) {
    return o && ((f_bool_sel)objc_msgSend)(o, SEL_("respondsToSelector:"), SEL_(s));
}
static BOOL iskind(id o, const char *cls) {
    Class c = objc_getClass(cls);
    return o && c && ((f_bool_id)objc_msgSend)(o, SEL_("isKindOfClass:"), (id)c);
}
static const char *clsname(id o) {
    return o ? class_getName(((f_class)objc_msgSend)(o, SEL_("class"))) : "nil";
}

/* autoreleased NSString from UTF-8, and UTF-8 back out */
static id nsstr(const char *s) {
    if (!s) return NULL;
    CFStringRef r = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    return r ? (id)CFAutorelease(r) : NULL;
}
static const char *cstr(id s) {
    return s ? ((f_cstr)objc_msgSend)(s, SEL_("UTF8String")) : NULL;
}
/* a no-arg selector that returns an NSString; NULL if absent or not a string */
static const char *strprop(id o, const char *sel) {
    if (!responds(o, sel)) return NULL;
    id r = msg(o, sel);
    if (!r || !iskind(r, "NSString")) return NULL;
    return cstr(r);
}
static id nsapp(void) { return msg(CLS("NSApplication"), "sharedApplication"); }
static double uptime(void) {
    return ((f_double)objc_msgSend)(msg(CLS("NSProcessInfo"), "processInfo"), SEL_("systemUptime"));
}

/* ------------------------------------------------------------------ */
/* growable output buffer + JSON helpers                              */
/* ------------------------------------------------------------------ */

typedef struct { char *p; size_t len, cap; } buf_t;

static void buf_reserve(buf_t *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) return;
    size_t nc = b->cap ? b->cap : 1024;
    while (nc < b->len + extra + 1) nc *= 2;
    b->p = realloc(b->p, nc);
    b->cap = nc;
}
static void buf_puts(buf_t *b, const char *s) {
    size_t n = strlen(s);
    buf_reserve(b, n);
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}
static void buf_printf(buf_t *b, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) { va_end(ap2); return; }
    buf_reserve(b, (size_t)n);
    vsnprintf(b->p + b->len, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)n;
}
static void buf_json_str(buf_t *b, const char *s) {
    if (!s) { buf_puts(b, "null"); return; }
    buf_puts(b, "\"");
    for (const unsigned char *c = (const unsigned char *)s; *c; c++) {
        switch (*c) {
        case '"':  buf_puts(b, "\\\""); break;
        case '\\': buf_puts(b, "\\\\"); break;
        case '\n': buf_puts(b, "\\n");  break;
        case '\r': buf_puts(b, "\\r");  break;
        case '\t': buf_puts(b, "\\t");  break;
        default:
            if (*c < 0x20) buf_printf(b, "\\u%04x", *c);
            else { buf_reserve(b, 1); b->p[b->len++] = (char)*c; b->p[b->len] = 0; }
        }
    }
    buf_puts(b, "\"");
}
static void buf_kv_str(buf_t *b, const char *k, const char *v) {
    if (!v) return;                       /* omit absent string fields */
    buf_printf(b, ",\"%s\":", k);
    buf_json_str(b, v);
}
static void buf_kv_bool(buf_t *b, const char *k, BOOL v) {
    buf_printf(b, ",\"%s\":%s", k, v ? "true" : "false");
}
static void buf_rect(buf_t *b, const char *k, CGRect r) {
    buf_printf(b, ",\"%s\":[%g,%g,%g,%g]", k, r.origin.x, r.origin.y, r.size.width, r.size.height);
}
static void buf_error(buf_t *b, const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    b->len = 0;
    if (b->p) b->p[0] = 0;
    buf_puts(b, "{\"ok\":false,\"error\":");
    buf_json_str(b, tmp);
    buf_puts(b, "}");
}

/* ------------------------------------------------------------------ */
/* shared state                                                       */
/* ------------------------------------------------------------------ */

#define MAX_WATCHERS 32
#define MAX_SUPPRESS 64
#define SYNTH_RING   128
#define SYNTH_EVNUM  0x5A1A           /* eventNumber tag on synthesized mouse events */

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int   g_watchers[MAX_WATCHERS];
static int   g_nwatchers;
static char *g_suppress[MAX_SUPPRESS];
static int   g_nsuppress;
static volatile int g_lock_input;       /* when set, real user input is dropped */
static volatile int g_hooked;
static char  g_sockpath[256];
static id    g_synth_ring[SYNTH_RING];  /* identities of events we posted (main thread) */
static int   g_synth_pos;

static void (*orig_sendEvent)(id, SEL, id);
static BOOL (*orig_sendAction)(id, SEL, SEL, id, id);

static void mark_synth(id ev) { g_synth_ring[g_synth_pos++ % SYNTH_RING] = ev; }
static bool take_synth(id ev) {
    for (int i = 0; i < SYNTH_RING; i++)
        if (g_synth_ring[i] == ev) { g_synth_ring[i] = NULL; return true; }
    return false;
}

static void broadcast(buf_t *b) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_nwatchers; ) {
        ssize_t r = send(g_watchers[i], b->p, b->len, MSG_DONTWAIT);
        if (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            g_watchers[i] = g_watchers[--g_nwatchers];   /* drop a dead watcher */
            continue;
        }
        i++;
    }
    pthread_mutex_unlock(&g_lock);
}
static void watcher_add(int fd) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_nwatchers; i++) if (g_watchers[i] == fd) goto out;
    if (g_nwatchers < MAX_WATCHERS) g_watchers[g_nwatchers++] = fd;
out:
    pthread_mutex_unlock(&g_lock);
}
static void watcher_remove(int fd) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_nwatchers; i++)
        if (g_watchers[i] == fd) { g_watchers[i] = g_watchers[--g_nwatchers]; break; }
    pthread_mutex_unlock(&g_lock);
}
static bool is_suppressed(const char *sel) {
    bool r = false;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_nsuppress; i++) if (!strcmp(g_suppress[i], sel)) { r = true; break; }
    pthread_mutex_unlock(&g_lock);
    return r;
}

/* ------------------------------------------------------------------ */
/* event description                                                  */
/* ------------------------------------------------------------------ */

static const char *event_type_name(unsigned long t) {
    switch (t) {
    case 1: return "leftMouseDown";     case 2: return "leftMouseUp";
    case 3: return "rightMouseDown";    case 4: return "rightMouseUp";
    case 5: return "mouseMoved";        case 6: return "leftMouseDragged";
    case 7: return "rightMouseDragged"; case 8: return "mouseEntered";
    case 9: return "mouseExited";       case 10: return "keyDown";
    case 11: return "keyUp";            case 12: return "flagsChanged";
    case 13: return "appKitDefined";    case 14: return "systemDefined";
    case 15: return "applicationDefined"; case 16: return "periodic";
    case 17: return "cursorUpdate";     case 18: return "rotate";
    case 19: return "beginGesture";     case 20: return "endGesture";
    case 22: return "scrollWheel";      case 23: return "tabletPoint";
    case 24: return "tabletProximity";  case 25: return "otherMouseDown";
    case 26: return "otherMouseUp";     case 27: return "otherMouseDragged";
    case 29: return "gesture";          case 30: return "magnify";
    case 31: return "swipe";            case 32: return "smartMagnify";
    case 34: return "pressure";         default: return "other";
    }
}
static bool is_mouse_type(unsigned long t) { return (t >= 1 && t <= 7) || (t >= 25 && t <= 27); }
static bool is_mouse_down(unsigned long t) { return t == 1 || t == 3 || t == 25; }
static bool is_key_type(unsigned long t)   { return t == 10 || t == 11; }
static bool is_user_input(unsigned long t) {
    return is_mouse_type(t) || is_key_type(t) || t == 12 || t == 22 || (t >= 29 && t <= 34);
}

static CGRect view_frame_in_window(id v);  /* fwd */

static void describe_event(buf_t *b, id ev, bool synthetic) {
    unsigned long t   = ((f_ulong)objc_msgSend)(ev, SEL_("type"));
    CGPoint loc       = ((f_point)objc_msgSend)(ev, SEL_("locationInWindow"));
    long wn           = msgl(ev, "windowNumber");
    unsigned long mod = ((f_ulong)objc_msgSend)(ev, SEL_("modifierFlags"));
    buf_printf(b, "{\"event\":\"input\",\"type\":%lu,\"name\":\"%s\",\"window\":%ld,\"x\":%g,\"y\":%g,\"mods\":%lu",
               t, event_type_name(t), wn, loc.x, loc.y, mod & 0xffff0000UL);
    buf_kv_bool(b, "synthetic", synthetic);
    if (is_mouse_type(t)) {
        buf_printf(b, ",\"clickCount\":%ld,\"button\":%ld", msgl(ev, "clickCount"), msgl(ev, "buttonNumber"));
        if (is_mouse_down(t)) {                         /* annotate what got hit */
            id win = msg(ev, "window");
            id cv  = win ? msg(win, "contentView") : NULL;
            id hit = cv ? ((f_id_point)objc_msgSend)(cv, SEL_("hitTest:"), loc) : NULL;
            if (hit) {
                buf_printf(b, ",\"view\":\"%p\",\"viewClass\":\"%s\"", (void *)hit, clsname(hit));
                buf_kv_str(b, "viewTitle", strprop(hit, "title"));
                buf_kv_str(b, "viewId", strprop(hit, "identifier"));
            }
        }
    } else if (is_key_type(t) || t == 12) {
        buf_printf(b, ",\"keyCode\":%u", ((f_ushort)objc_msgSend)(ev, SEL_("keyCode")));
        if (is_key_type(t)) {
            buf_kv_str(b, "chars", strprop(ev, "characters"));
            buf_kv_str(b, "charsIgnoringModifiers", strprop(ev, "charactersIgnoringModifiers"));
            buf_kv_bool(b, "repeat", msgb(ev, "isARepeat"));
        }
    }
    buf_puts(b, "}\n");
}

/* ------------------------------------------------------------------ */
/* the two hooks                                                      */
/* ------------------------------------------------------------------ */

static void hook_sendEvent(id self, SEL _cmd, id ev) {
    unsigned long t = ((f_ulong)objc_msgSend)(ev, SEL_("type"));
    bool synthetic  = take_synth(ev);
    /* AppKit's button/menu tracking loops pull a queued mouse event and
     * re-synthesize it, so pointer identity can miss. Our posted mouse events
     * carry a sentinel eventNumber that survives that round-trip. */
    if (!synthetic && is_mouse_type(t) && msgl(ev, "eventNumber") == SYNTH_EVNUM) synthetic = true;
    if (g_nwatchers > 0 && is_user_input(t)) {
        void *pool = objc_autoreleasePoolPush();
        buf_t b = {0};
        describe_event(&b, ev, synthetic);
        broadcast(&b);
        free(b.p);
        objc_autoreleasePoolPop(pool);
    }
    if (g_lock_input && !synthetic && is_user_input(t)) return;   /* swallow real input while locked */
    orig_sendEvent(self, _cmd, ev);
}

static BOOL hook_sendAction(id self, SEL _cmd, SEL action, id target, id sender) {
    const char *name = action ? sel_getName(action) : "(null)";
    bool suppressed  = is_suppressed(name);
    if (g_nwatchers > 0) {
        void *pool = objc_autoreleasePoolPush();
        buf_t b = {0};
        buf_puts(&b, "{\"event\":\"action\",\"selector\":");
        buf_json_str(&b, name);
        buf_printf(&b, ",\"target\":\"%p\",\"targetClass\":\"%s\",\"sender\":\"%p\",\"senderClass\":\"%s\"",
                   (void *)target, target ? clsname(target) : "nil",
                   (void *)sender, sender ? clsname(sender) : "nil");
        buf_kv_str(&b, "senderTitle", strprop(sender, "title"));
        buf_kv_str(&b, "senderId", strprop(sender, "identifier"));
        buf_kv_bool(&b, "suppressed", suppressed);
        buf_puts(&b, "}\n");
        broadcast(&b);
        free(b.p);
        objc_autoreleasePoolPop(pool);
    }
    if (suppressed) return NO;
    return orig_sendAction(self, _cmd, action, target, sender);
}

static id all_windows(void);   /* fwd: defined in the window-helpers section */

static void install_hooks(void) {
    if (g_hooked) return;
    Class app = objc_getClass("NSApplication");
    if (!app) return;
    Method m1 = class_getInstanceMethod(app, SEL_("sendEvent:"));
    Method m2 = class_getInstanceMethod(app, SEL_("sendAction:to:from:"));
    if (!m1 || !m2) return;
    orig_sendEvent  = (void (*)(id, SEL, id))method_setImplementation(m1, (IMP)hook_sendEvent);
    orig_sendAction = (BOOL (*)(id, SEL, SEL, id, id))method_setImplementation(m2, (IMP)hook_sendAction);
    g_hooked = 1;
    extern void install_headless_if_requested(void);
    install_headless_if_requested();
}

/* ------------------------------------------------------------------ */
/* headless / offscreen mode ("virtualize the GUI")                   */
/*                                                                    */
/* Interpose, don't reimplement: the real AppKit still runs, but we   */
/* relocate every window far offscreen as it is ordered in. The app   */
/* behaves identically -- event routing, key status, drawing, and     */
/* target/action all work -- while nothing reaches a physical display.*/
/* The app runs unaware; the shim drives and screenshots it through   */
/* the usual socket commands. Enable with APPSHIM_HEADLESS=1.          */
/* ------------------------------------------------------------------ */

#define OFFSCREEN_X 200000.0
#define OFFSCREEN_Y 200000.0

static volatile int g_headless;           /* set in the constructor from the env */
static volatile int g_headless_installed;
static void (*orig_mkKeyFront)(id, SEL, id);
static void (*orig_orderFront)(id, SEL, id);

typedef void (*f_void_point)(id, SEL, CGPoint);

/* APPSHIM_PLACE="x,y,w,h" (global top-left coordinates, as CoreGraphics
 * uses): put every window there as it is ordered in, e.g. on a virtual display
 * that `uidrive display` holds. A window created on a display stays there,
 * where moving it afterwards may be undone by a tiling window manager. */
static volatile int g_place;
static CGRect g_place_rect;

static void shove_offscreen(id win) {
    if (g_place) {
        CGRect main_bounds = CGDisplayBounds(CGMainDisplayID());
        CGRect r = g_place_rect;
        r.origin.y = main_bounds.size.height - (r.origin.y + r.size.height);
        /* only a window that is not on the target display yet: one already
         * there (placed, or tiled by a window manager) is left alone, since
         * resizing a window under an app can leave its drawing at the old size */
        CGRect now = msgrect(win, "frame");
        if (CGRectIntersectsRect(now, r)) return;
        ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(win, SEL_("setFrame:display:"), r, YES);
        return;
    }
    CGPoint p = { OFFSCREEN_X, OFFSCREEN_Y };
    ((f_void_point)objc_msgSend)(win, SEL_("setFrameOrigin:"), p);
}
static void hook_mkKeyFront(id self, SEL _cmd, id sender) {
    orig_mkKeyFront(self, _cmd, sender);
    if (g_headless || g_place) shove_offscreen(self);
}
static void hook_orderFront(id self, SEL _cmd, id sender) {
    orig_orderFront(self, _cmd, sender);
    if (g_headless || g_place) shove_offscreen(self);
}
/* AppKit normally clamps a window's frame to stay reachable on some screen.
 * Returning the requested rect unchanged lets a window sit fully offscreen. */
static CGRect hook_constrain(id self, SEL _cmd, CGRect r, id screen) {
    (void)self; (void)_cmd; (void)screen;
    return r;
}

/* Install the offscreen interposition. Called from install_hooks (a path we
 * know runs on the main thread), guarded so it happens at most once. */
static void install_headless(void) {
    if (g_headless_installed) return;
    Class win = objc_getClass("NSWindow");
    if (!win) return;
    Method a = class_getInstanceMethod(win, SEL_("makeKeyAndOrderFront:"));
    Method b = class_getInstanceMethod(win, SEL_("orderFront:"));
    Method c = class_getInstanceMethod(win, SEL_("constrainFrameRect:toScreen:"));
    if (a) orig_mkKeyFront  = (void (*)(id, SEL, id))method_setImplementation(a, (IMP)hook_mkKeyFront);
    if (b) orig_orderFront  = (void (*)(id, SEL, id))method_setImplementation(b, (IMP)hook_orderFront);
    if (c) method_setImplementation(c, (IMP)hook_constrain);
    id appobj = nsapp();
    if (appobj && g_headless) ((f_void_long)objc_msgSend)(appobj, SEL_("setActivationPolicy:"), 1 /* Accessory: no Dock icon */);
    g_headless_installed = 1;
    id arr = all_windows();                /* relocate any already-open windows */
    long n = arr ? msgl(arr, "count") : 0;
    for (long i = 0; i < n; i++) {
        id w = msg_long(arr, "objectAtIndex:", i);
        if (msgb(w, "isVisible")) shove_offscreen(w);
    }
    if (g_place) fprintf(stderr, "[appshim] windows placed at %g,%g %gx%g\n", g_place_rect.origin.x,
                         g_place_rect.origin.y, g_place_rect.size.width, g_place_rect.size.height);
    else fprintf(stderr, "[appshim] headless mode: windows kept offscreen\n");
}
void install_headless_if_requested(void) { if (g_headless || g_place) install_headless(); }

/* ------------------------------------------------------------------ */
/* window / view helpers (main thread only)                           */
/* ------------------------------------------------------------------ */

static id all_windows(void) { return msg(nsapp(), "windows"); }

static id window_by_number(long n) {
    id arr = all_windows();
    long c = msgl(arr, "count");
    for (long i = 0; i < c; i++) {
        id w = msg_long(arr, "objectAtIndex:", i);
        if (msgl(w, "windowNumber") == n) return w;
    }
    return NULL;
}
static id default_window(void) {
    id app = nsapp();
    id w = msg(app, "keyWindow");
    if (!w) w = msg(app, "mainWindow");
    if (!w) {
        id arr = all_windows();
        long c = msgl(arr, "count");
        for (long i = 0; i < c; i++) {
            id cand = msg_long(arr, "objectAtIndex:", i);
            if (msgb(cand, "isVisible")) { w = cand; break; }
        }
    }
    return w;
}
/* window from an arg string: "key"/"-" -> default, else a window number */
static id window_arg(const char *s) {
    if (!s || !strcmp(s, "key") || !strcmp(s, "-")) return default_window();
    char *end;
    long n = strtol(s, &end, 10);
    if (*end) return NULL;
    return window_by_number(n);
}

static CGRect view_frame_in_window(id v) {
    CGRect bounds = msgrect(v, "bounds");
    return ((f_rect_rect_id)MSGSEND_STRET)(v, SEL_("convertRect:toView:"), bounds, NULL);
}
static bool tree_contains(id root, id target) {
    if (!root) return false;
    if (root == target) return true;
    id subs = msg(root, "subviews");
    long c = subs ? msgl(subs, "count") : 0;
    for (long i = 0; i < c; i++)
        if (tree_contains(msg_long(subs, "objectAtIndex:", i), target)) return true;
    return false;
}
/* a window's topmost view: the frame view if reachable, else the content view */
static id window_root(id w) {
    id cv = msg(w, "contentView");
    if (!cv) return NULL;
    id sup = msg(cv, "superview");
    return sup ? sup : cv;
}
/* resolve "0x..." to a view that is still live in some window's hierarchy */
static id view_by_id(const char *s, id *out_win) {
    if (!s) return NULL;
    uintptr_t p = (uintptr_t)strtoull(s, NULL, 16);
    if (!p) return NULL;
    id arr = all_windows();
    long c = msgl(arr, "count");
    for (long i = 0; i < c; i++) {
        id w = msg_long(arr, "objectAtIndex:", i);
        if (tree_contains(window_root(w), (id)p)) { if (out_win) *out_win = w; return (id)p; }
    }
    return NULL;
}

static void emit_view(buf_t *b, id v, bool recurse) {
    buf_printf(b, "{\"id\":\"%p\",\"class\":\"%s\"", (void *)v, clsname(v));
    buf_rect(b, "frame", view_frame_in_window(v));
    buf_kv_bool(b, "hidden", msgb(v, "isHiddenOrHasHiddenAncestor"));
    buf_kv_str(b, "title", strprop(v, "title"));
    if (iskind(v, "NSControl"))       buf_kv_str(b, "value", strprop(v, "stringValue"));
    else if (iskind(v, "NSTextView")) buf_kv_str(b, "value", strprop(v, "string"));
    buf_kv_str(b, "placeholder", strprop(v, "placeholderString"));
    buf_kv_str(b, "identifier",  strprop(v, "identifier"));
    buf_kv_str(b, "axid",        strprop(v, "accessibilityIdentifier"));
    buf_kv_str(b, "role",        strprop(v, "accessibilityRole"));
    buf_kv_str(b, "label",       strprop(v, "accessibilityLabel"));
    buf_kv_str(b, "tooltip",     strprop(v, "toolTip"));
    if (responds(v, "isEnabled")) buf_kv_bool(b, "enabled", msgb(v, "isEnabled"));
    if (iskind(v, "NSButton"))    buf_printf(b, ",\"state\":%ld", msgl(v, "state"));
    if (iskind(v, "NSControl") && responds(v, "action")) {
        SEL a = ((f_sel)objc_msgSend)(v, SEL_("action"));
        if (a) buf_kv_str(b, "action", sel_getName(a));
    }
    if (recurse) {
        buf_puts(b, ",\"children\":[");
        id subs = msg(v, "subviews");
        long c = subs ? msgl(subs, "count") : 0;
        for (long i = 0; i < c; i++) {
            if (i) buf_puts(b, ",");
            emit_view(b, msg_long(subs, "objectAtIndex:", i), true);
        }
        buf_puts(b, "]");
    }
    buf_puts(b, "}");
}
static void emit_window(buf_t *b, id w) {
    buf_printf(b, "{\"number\":%ld,\"class\":\"%s\"", msgl(w, "windowNumber"), clsname(w));
    buf_kv_str(b, "title", strprop(w, "title"));
    buf_rect(b, "frame", msgrect(w, "frame"));
    buf_kv_bool(b, "visible", msgb(w, "isVisible"));
    buf_kv_bool(b, "key", msgb(w, "isKeyWindow"));
    buf_kv_bool(b, "main", msgb(w, "isMainWindow"));
    id cv = msg(w, "contentView");
    if (cv) buf_printf(b, ",\"contentView\":\"%p\"", (void *)cv);
    buf_puts(b, "}");
}

static bool ci_contains(const char *hay, const char *needle) {
    return hay && strcasestr(hay, needle) != NULL;
}
static bool view_matches(id v, const char *q) {
    static const char *props[] = { "title", "identifier", "accessibilityIdentifier",
                                   "accessibilityLabel", "placeholderString", "toolTip", NULL };
    if (ci_contains(clsname(v), q)) return true;
    for (int i = 0; props[i]; i++) if (ci_contains(strprop(v, props[i]), q)) return true;
    if (iskind(v, "NSControl")  && ci_contains(strprop(v, "stringValue"), q)) return true;
    if (iskind(v, "NSTextView") && ci_contains(strprop(v, "string"), q)) return true;
    return false;
}
static void find_in_tree(buf_t *b, id v, long wn, const char *q, int *count) {
    if (view_matches(v, q)) {
        if ((*count)++) buf_puts(b, ",");
        buf_printf(b, "{\"window\":%ld,\"view\":", wn);
        emit_view(b, v, false);
        buf_puts(b, "}");
    }
    id subs = msg(v, "subviews");
    long c = subs ? msgl(subs, "count") : 0;
    for (long i = 0; i < c; i++) find_in_tree(b, msg_long(subs, "objectAtIndex:", i), wn, q, count);
}

/* ------------------------------------------------------------------ */
/* synthetic input (main thread)                                      */
/* ------------------------------------------------------------------ */

static unsigned long parse_mods(const char *s) {
    unsigned long m = 0;
    if (!s) return 0;
    if (strcasestr(s, "shift")) m |= 1UL << 17;
    if (strcasestr(s, "ctrl") || strcasestr(s, "control")) m |= 1UL << 18;
    if (strcasestr(s, "alt")  || strcasestr(s, "opt"))     m |= 1UL << 19;
    if (strcasestr(s, "cmd")  || strcasestr(s, "command")) m |= 1UL << 20;
    if (strcasestr(s, "fn")) m |= 1UL << 23;
    return m;
}
static void post_event(id ev) {
    if (!ev) return;
    mark_synth(ev);
    ((f_void_id_bool)objc_msgSend)(nsapp(), SEL_("postEvent:atStart:"), ev, NO);
}
static void synth_click(id win, CGPoint p, int button, long clicks, unsigned long mods) {
    long wn = msgl(win, "windowNumber");
    unsigned long down = button == 1 ? 3 : button == 2 ? 25 : 1;
    unsigned long up   = button == 1 ? 4 : button == 2 ? 26 : 2;
    double ts = uptime();
    f_mouseEvent mk = (f_mouseEvent)objc_msgSend;
    id cls = CLS("NSEvent");
    SEL sel = SEL_("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:");
    for (long c = 1; c <= clicks; c++) {
        post_event(mk(cls, sel, down, p, mods, ts,        wn, NULL, SYNTH_EVNUM, c, 1.0f));
        post_event(mk(cls, sel, up,   p, mods, ts + 0.02, wn, NULL, SYNTH_EVNUM, c, 0.0f));
        ts += 0.05;
    }
}
static void synth_key(id win, unsigned short keycode, unsigned long mods, id chars, id charsIgn) {
    long wn = win ? msgl(win, "windowNumber") : 0;
    double ts = uptime();
    f_keyEvent mk = (f_keyEvent)objc_msgSend;
    id cls = CLS("NSEvent");
    SEL sel = SEL_("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:");
    CGPoint z = {0, 0};
    if (!chars)    chars = nsstr("");
    if (!charsIgn) charsIgn = chars;
    post_event(mk(cls, sel, 10, z, mods, ts,        wn, NULL, chars, charsIgn, NO, keycode));
    post_event(mk(cls, sel, 11, z, mods, ts + 0.02, wn, NULL, chars, charsIgn, NO, keycode));
}
/* type a string by delivering one keyDown/keyUp pair per character. keyCode 0
 * is accepted by most text controls since they read -characters. */
static void synth_type(id win, const char *utf8) {
    id s = nsstr(utf8);
    if (!s) return;
    long n = msgl(s, "length");
    for (long i = 0; i < n; i++) {
        unsigned short u = ((unsigned short (*)(id, SEL, long))objc_msgSend)(s, SEL_("characterAtIndex:"), i);
        CFStringRef cf = CFStringCreateWithCharacters(NULL, &u, 1);
        id one = cf ? (id)CFAutorelease(cf) : NULL;
        synth_key(win, 0, 0, one, one);
    }
}

/* ------------------------------------------------------------------ */
/* menus                                                              */
/* ------------------------------------------------------------------ */

/* An item's user-visible label. For an item that owns a submenu (menu-bar
 * entries, and any submenu parent) the name shown in the UI is the submenu's
 * title, so prefer that; otherwise use the item's own title. */
static const char *item_label(id it) {
    if (msgb(it, "hasSubmenu")) {
        const char *s = strprop(msg(it, "submenu"), "title");
        if (s && *s) return s;
    }
    const char *t = strprop(it, "title");
    return (t && *t) ? t : strprop(it, "title");
}

static void emit_menu(buf_t *b, id menu) {
    buf_puts(b, "[");
    id items = msg(menu, "itemArray");
    long c = items ? msgl(items, "count") : 0;
    for (long i = 0; i < c; i++) {
        id it = msg_long(items, "objectAtIndex:", i);
        if (i) buf_puts(b, ",");
        if (msgb(it, "isSeparatorItem")) { buf_puts(b, "{\"separator\":true}"); continue; }
        buf_printf(b, "{\"index\":%ld", i);
        buf_kv_str(b, "title", item_label(it));
        buf_kv_bool(b, "enabled", msgb(it, "isEnabled"));
        buf_printf(b, ",\"state\":%ld", msgl(it, "state"));
        const char *ke = strprop(it, "keyEquivalent");
        if (ke && *ke) buf_kv_str(b, "key", ke);
        SEL a = ((f_sel)objc_msgSend)(it, SEL_("action"));
        if (a) buf_kv_str(b, "action", sel_getName(a));
        if (msgb(it, "hasSubmenu")) { buf_puts(b, ",\"items\":"); emit_menu(b, msg(it, "submenu")); }
        buf_puts(b, "}");
    }
    buf_puts(b, "]");
}
static void rtrim(char *s) {
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
}
static bool menu_title_match(const char *title, const char *want) {
    if (!title) return false;
    if (!strcasecmp(title, want)) return true;
    size_t n = strlen(want);                       /* allow a trailing ellipsis on the real title */
    return strncasecmp(title, want, n) == 0 &&
           (title[n] == 0 || !strncmp(title + n, "\xe2\x80\xa6", 3) || !strncmp(title + n, "...", 3));
}
/* walk "File>Save As" and fire the leaf item. returns NULL ok, else error text */
static const char *menu_perform(const char *path, buf_t *b) {
    char tmp[1024];
    strlcpy(tmp, path, sizeof tmp);
    id menu = msg(nsapp(), "mainMenu");
    if (!menu) return "no main menu";
    char *save = NULL;
    for (char *tok = strtok_r(tmp, ">", &save); tok; tok = strtok_r(NULL, ">", &save)) {
        while (*tok == ' ') tok++;
        rtrim(tok);
        id items = msg(menu, "itemArray");
        long c = msgl(items, "count"), found = -1;
        for (long i = 0; i < c && found < 0; i++)
            if (menu_title_match(item_label(msg_long(items, "objectAtIndex:", i)), tok)) found = i;
        if (found < 0) return "menu item not found";
        id item = msg_long(items, "objectAtIndex:", found);
        bool leaf = !(save && *save);
        if (!leaf) {
            if (!msgb(item, "hasSubmenu")) return "intermediate item has no submenu";
            menu = msg(item, "submenu");
        } else {
            if (!msgb(item, "isEnabled")) return "menu item disabled";
            ((f_void_long)objc_msgSend)(menu, SEL_("performActionForItemAtIndex:"), found);
            buf_puts(b, "{\"ok\":true,\"performed\":");
            buf_json_str(b, item_label(item));
            buf_puts(b, "}");
            return NULL;
        }
    }
    return "empty menu path";
}

/* ------------------------------------------------------------------ */
/* screenshot: render a window's content view into a PNG              */
/* ------------------------------------------------------------------ */

static const char *window_screenshot(id win, const char *path) {
    id view = msg(win, "contentView");
    if (!view) return "window has no content view";
    CGRect bounds = msgrect(view, "bounds");
    id rep = ((f_id_rect)objc_msgSend)(view, SEL_("bitmapImageRepForCachingDisplayInRect:"), bounds);
    if (!rep) return "could not allocate bitmap";
    ((f_void_rect_id)objc_msgSend)(view, SEL_("cacheDisplayInRect:toBitmapImageRep:"), bounds, rep);
    /* NSBitmapImageRep -> PNG data (NSBitmapImageFileTypePNG == 4) */
    id data = ((id (*)(id, SEL, unsigned long, id))objc_msgSend)(
        rep, SEL_("representationUsingType:properties:"), 4,
        msg(CLS("NSDictionary"), "dictionary"));
    if (!data) return "PNG encode failed";
    BOOL ok = ((f_bool_id_bool)objc_msgSend)(data, SEL_("writeToFile:atomically:"), nsstr(path), YES);
    return ok ? NULL : "write failed";
}

/* ------------------------------------------------------------------ */
/* command dispatch                                                   */
/* ------------------------------------------------------------------ */

typedef struct { int argc; char **argv; buf_t out; int fd; bool want_watch, want_unwatch; } req_t;

/* Is the libdispatch main queue actually being drained? In a native AppKit app
 * the main run loop drains it, so marshalling with dispatch_sync works. In a
 * host with its own main-thread loop (Gecko, some Qt builds) it may not, and a
 * dispatch_sync would deadlock. Probe once with a timeout and cache the result;
 * the probe block only touches a process-lifetime semaphore, so it is safe even
 * if it runs late. */
static dispatch_semaphore_t g_probe_sem;
static volatile int g_main_alive = -1;        /* -1 unknown, 0 no, 1 yes */
static void probe_fn(void *ctx) { (void)ctx; dispatch_semaphore_signal(g_probe_sem); }
static int main_queue_ok(void) {
    if (g_main_alive != -1) return g_main_alive;
    g_probe_sem = dispatch_semaphore_create(0);
    dispatch_async_f(dispatch_get_main_queue(), NULL, probe_fn);
    long r = dispatch_semaphore_wait(g_probe_sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)2 * NSEC_PER_SEC));
    g_main_alive = (r == 0) ? 1 : 0;
    return g_main_alive;
}

static void cmd_help(buf_t *b) {
    buf_puts(b, "{\"ok\":true,\"commands\":["
        "\"ping\",\"windows\",\"tree [win] [all]\",\"find <text>\",\"get <viewid>\","
        "\"at <win> <x> <y>\",\"click <viewid> [count] [mods]\",\"rclick <viewid>\","
        "\"mouse <win> <x> <y> [left|right|middle] [count] [mods]\",\"press <viewid>\","
        "\"action <viewid>\",\"focus <viewid>\",\"settext <viewid> <text>\",\"type <text>\","
        "\"key <keycode> [mods|-] [chars]\",\"keyev down|up|flags <keycode> <modmask> [chars]\",\"setframe <win> <x> <y> <w> <h>\",\"nudge [win]\",\"perform <viewid> <selector>\",\"menus\","
        "\"menu <A>B>C>\",\"screenshot <win> <path.png>\",\"activate\",\"watch\",\"unwatch\","
        "\"lock on|off\",\"suppress <selector>\",\"unsuppress <selector>\",\"suppressed\",\"help\"]}");
}

/* executed on the main thread via dispatch_sync_f */
static void handle_on_main(void *ctx) {
    req_t *r  = ctx;
    buf_t *b  = &r->out;
    int argc  = r->argc;
    char **argv = r->argv;
    void *pool = objc_autoreleasePoolPush();
    install_hooks();
    const char *cmd = argv[0];
    id win = NULL;

    if (!strcmp(cmd, "ping")) {
        buf_printf(b, "{\"ok\":true,\"pid\":%d,\"process\":", getpid());
        buf_json_str(b, getprogname());
        buf_printf(b, ",\"hooked\":%s,\"watchers\":%d,\"locked\":%s}",
                   g_hooked ? "true" : "false", g_nwatchers, g_lock_input ? "true" : "false");
    }
    else if (!strcmp(cmd, "help")) cmd_help(b);
    else if (!strcmp(cmd, "activate")) {
        msgv_id(nsapp(), "activateIgnoringOtherApps:", (id)(uintptr_t)1);
        buf_puts(b, "{\"ok\":true}");
    }
    else if (!strcmp(cmd, "windows")) {
        id arr = all_windows();
        long c = msgl(arr, "count");
        buf_puts(b, "{\"ok\":true,\"windows\":[");
        for (long i = 0; i < c; i++) { if (i) buf_puts(b, ","); emit_window(b, msg_long(arr, "objectAtIndex:", i)); }
        buf_puts(b, "]}");
    }
    else if (!strcmp(cmd, "tree")) {
        win = window_arg(argc > 1 ? argv[1] : NULL);
        if (!win) { buf_error(b, "no such window"); goto done; }
        bool all = (argc > 2 && !strcmp(argv[2], "all")) || (argc > 1 && !strcmp(argv[1], "all"));
        id root = all ? window_root(win) : msg(win, "contentView");
        if (!root) { buf_error(b, "window has no content view"); goto done; }
        buf_puts(b, "{\"ok\":true,\"window\":");
        emit_window(b, win);
        buf_puts(b, ",\"root\":");
        emit_view(b, root, true);
        buf_puts(b, "}");
    }
    else if (!strcmp(cmd, "find")) {
        if (argc < 2) { buf_error(b, "usage: find <text>"); goto done; }
        id arr = all_windows();
        long c = msgl(arr, "count");
        int count = 0;
        buf_puts(b, "{\"ok\":true,\"matches\":[");
        for (long i = 0; i < c; i++) {
            id w = msg_long(arr, "objectAtIndex:", i);
            id root = window_root(w);
            if (root) find_in_tree(b, root, msgl(w, "windowNumber"), argv[1], &count);
        }
        buf_puts(b, "]}");
    }
    else if (!strcmp(cmd, "get")) {
        id v = view_by_id(argc > 1 ? argv[1] : NULL, &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        buf_printf(b, "{\"ok\":true,\"window\":%ld,\"view\":", msgl(win, "windowNumber"));
        emit_view(b, v, false);
        buf_puts(b, "}");
    }
    else if (!strcmp(cmd, "at")) {
        if (argc < 4) { buf_error(b, "usage: at <win> <x> <y>"); goto done; }
        win = window_arg(argv[1]);
        if (!win) { buf_error(b, "no such window"); goto done; }
        CGPoint p = { atof(argv[2]), atof(argv[3]) };
        id cv = msg(win, "contentView");
        id hit = cv ? ((f_id_point)objc_msgSend)(cv, SEL_("hitTest:"), p) : NULL;
        if (!hit) { buf_puts(b, "{\"ok\":true,\"view\":null}"); goto done; }
        buf_puts(b, "{\"ok\":true,\"view\":");
        emit_view(b, hit, false);
        buf_puts(b, "}");
    }
    else if (!strcmp(cmd, "click") || !strcmp(cmd, "rclick")) {
        id v = view_by_id(argc > 1 ? argv[1] : NULL, &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        if (msgb(v, "isHiddenOrHasHiddenAncestor")) { buf_error(b, "view is hidden"); goto done; }
        CGRect f = view_frame_in_window(v);
        CGPoint p = { f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2 };
        long clicks = argc > 2 ? atol(argv[2]) : 1;
        if (clicks < 1) clicks = 1;
        synth_click(win, p, cmd[0] == 'r' ? 1 : 0, clicks, parse_mods(argc > 3 ? argv[3] : NULL));
        buf_printf(b, "{\"ok\":true,\"window\":%ld,\"x\":%g,\"y\":%g,\"clicks\":%ld}",
                   msgl(win, "windowNumber"), p.x, p.y, clicks);
    }
    else if (!strcmp(cmd, "mouse")) {
        if (argc < 4) { buf_error(b, "usage: mouse <win> <x> <y> [left|right|middle] [count] [mods]"); goto done; }
        win = window_arg(argv[1]);
        if (!win) { buf_error(b, "no such window"); goto done; }
        CGPoint p = { atof(argv[2]), atof(argv[3]) };
        int button = 0;
        if (argc > 4) button = !strcmp(argv[4], "right") ? 1 : !strcmp(argv[4], "middle") ? 2 : 0;
        long clicks = argc > 5 ? atol(argv[5]) : 1;
        if (clicks < 1) clicks = 1;
        synth_click(win, p, button, clicks, parse_mods(argc > 6 ? argv[6] : NULL));
        buf_printf(b, "{\"ok\":true,\"window\":%ld,\"x\":%g,\"y\":%g,\"clicks\":%ld}",
                   msgl(win, "windowNumber"), p.x, p.y, clicks);
    }
    else if (!strcmp(cmd, "press")) {
        id v = view_by_id(argc > 1 ? argv[1] : NULL, &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        if (!responds(v, "performClick:")) { buf_error(b, "view has no performClick:"); goto done; }
        msgv_id(v, "performClick:", NULL);
        buf_puts(b, "{\"ok\":true}");
    }
    else if (!strcmp(cmd, "action")) {
        id v = view_by_id(argc > 1 ? argv[1] : NULL, &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        if (!iskind(v, "NSControl")) { buf_error(b, "not an NSControl"); goto done; }
        SEL a = ((f_sel)objc_msgSend)(v, SEL_("action"));
        if (!a) { buf_error(b, "control has no action"); goto done; }
        BOOL ok = ((f_bool_sel_id_id)objc_msgSend)(nsapp(), SEL_("sendAction:to:from:"),
                                                   a, msg(v, "target"), v);
        buf_printf(b, "{\"ok\":true,\"sent\":%s,\"selector\":\"%s\"}", ok ? "true" : "false", sel_getName(a));
    }
    else if (!strcmp(cmd, "perform")) {
        if (argc < 3) { buf_error(b, "usage: perform <viewid> <selector>"); goto done; }
        id v = view_by_id(argv[1], &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        if (!responds(v, argv[2])) { buf_error(b, "view does not respond to %s", argv[2]); goto done; }
        msgv_id(v, argv[2], NULL);          /* fire selector with a nil sender */
        buf_printf(b, "{\"ok\":true,\"performed\":\"%s\"}", argv[2]);
    }
    else if (!strcmp(cmd, "focus")) {
        id v = view_by_id(argc > 1 ? argv[1] : NULL, &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        msgv_id(win, "makeKeyAndOrderFront:", NULL);
        BOOL ok = ((f_bool_id)objc_msgSend)(win, SEL_("makeFirstResponder:"), v);
        buf_printf(b, "{\"ok\":true,\"firstResponder\":%s}", ok ? "true" : "false");
    }
    else if (!strcmp(cmd, "settext")) {
        if (argc < 3) { buf_error(b, "usage: settext <viewid> <text>"); goto done; }
        id v = view_by_id(argv[1], &win);
        if (!v) { buf_error(b, "no such view"); goto done; }
        id s = nsstr(argv[2]);
        if (iskind(v, "NSTextView")) msgv_id(v, "setString:", s);
        else if (responds(v, "setStringValue:")) msgv_id(v, "setStringValue:", s);
        else { buf_error(b, "view has no text setter"); goto done; }
        buf_puts(b, "{\"ok\":true}");
    }
    else if (!strcmp(cmd, "type")) {
        if (argc < 2) { buf_error(b, "usage: type <text>"); goto done; }
        synth_type(default_window(), argv[1]);
        buf_puts(b, "{\"ok\":true}");
    }
    else if (!strcmp(cmd, "key")) {
        if (argc < 2) { buf_error(b, "usage: key <keycode> [mods|-] [chars]"); goto done; }
        unsigned short kc = (unsigned short)atoi(argv[1]);
        unsigned long mods = (argc > 2 && strcmp(argv[2], "-")) ? parse_mods(argv[2]) : 0;
        id chars = argc > 3 ? nsstr(argv[3]) : NULL;
        synth_key(default_window(), kc, mods, chars, chars);
        buf_puts(b, "{\"ok\":true}");
    }
    else if (!strcmp(cmd, "setframe")) {
        /* setframe <win> <x> <y> <w> <h>: global top-left coordinates, as
         * CoreGraphics and the Accessibility API use them (y grows down from
         * the top of the main display); converted to AppKit's bottom-left. */
        if (argc < 6) { buf_error(b, "usage: setframe <win> <x> <y> <w> <h>"); goto done; }
        id w = window_arg(argv[1]);
        if (!w) { buf_error(b, "no such window"); goto done; }
        double x = atof(argv[2]), y = atof(argv[3]), ww = atof(argv[4]), hh = atof(argv[5]);
        CGRect main_bounds = CGDisplayBounds(CGMainDisplayID());
        CGRect r = { { x, main_bounds.size.height - (y + hh) }, { ww, hh } };
        ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(w, SEL_("setFrame:display:"), r, YES);
        CGRect f = msgrect(w, "frame");
        buf_printf(b, "{\"ok\":true,\"frame\":[%g,%g,%g,%g]}", f.origin.x, f.origin.y, f.size.width, f.size.height);
    }
    else if (!strcmp(cmd, "nudge")) {
        /* nudge [win]: shrink the window by 2 points and restore it. Apps that
         * size their drawing from the display they were created on recompute
         * it on a resize (after a move to a display of another scale). */
        id w = window_arg(argc > 1 ? argv[1] : NULL);
        if (!w) { buf_error(b, "no such window"); goto done; }
        CGRect f = msgrect(w, "frame");
        CGRect g = f; g.size.width -= 2;
        ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(w, SEL_("setFrame:display:"), g, YES);
        ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(w, SEL_("setFrame:display:"), f, YES);
        buf_printf(b, "{\"ok\":true,\"frame\":[%g,%g,%g,%g]}", f.origin.x, f.origin.y, f.size.width, f.size.height);
    }
    else if (!strcmp(cmd, "keyev")) {
        /* keyev down|up|flags <keycode> <modmask> [chars]: one raw key event
         * handed straight to the window's first responder, bypassing NSApp's
         * key-window routing, so it reaches an app that is not frontmost.
         * modmask is NSEventModifierFlags as a number (uidrive sends these). */
        if (argc < 4) { buf_error(b, "usage: keyev down|up|flags <keycode> <modmask> [chars]"); goto done; }
        unsigned long type = !strcmp(argv[1], "down") ? 10 : !strcmp(argv[1], "up") ? 11 :
                             !strcmp(argv[1], "flags") ? 12 : 0;
        if (!type) { buf_error(b, "type must be down, up or flags"); goto done; }
        id w = default_window();
        if (!w) { buf_error(b, "no window"); goto done; }
        /* chars as u+HEX (one UTF-16 unit) so any character survives the line protocol */
        id chars = nsstr("");
        if (argc > 4 && type != 12 && !strncmp(argv[4], "u+", 2)) {
            unsigned short u = (unsigned short)strtoul(argv[4] + 2, NULL, 16);
            CFStringRef cf = CFStringCreateWithCharacters(NULL, &u, 1);
            if (cf) chars = (id)CFAutorelease(cf);
        } else if (argc > 4 && type != 12) chars = nsstr(argv[4]);
        f_keyEvent mk = (f_keyEvent)objc_msgSend;
        SEL sel = SEL_("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:");
        CGPoint z = {0, 0};
        id ev = mk(CLS("NSEvent"), sel, type, z, strtoul(argv[3], NULL, 10), uptime(),
                   msgl(w, "windowNumber"), NULL, chars, chars, NO, (unsigned short)atoi(argv[2]));
        if (!ev) { buf_error(b, "could not build the event"); goto done; }
        mark_synth(ev);
        /* a window macOS considers hidden (occluded) stops drawing; bring it
         * forward again. NSWindowOcclusionStateVisible is 1 << 1. */
        if (!(msgl(w, "occlusionState") & 2)) msgv_id(w, "orderFront:", NULL);
        /* the first responder directly: -[NSWindow sendEvent:] drops key
         * events while the window is not key, which it never is when the
         * app is in the background */
        id fr = msg(w, "firstResponder");
        if (!fr) fr = msg(w, "contentView");
        const char *sel_name = type == 10 ? "keyDown:" : type == 11 ? "keyUp:" : "flagsChanged:";
        if (!responds(fr, sel_name)) { buf_error(b, "first responder does not take %s", sel_name); goto done; }
        msgv_id(fr, sel_name, ev);
        buf_printf(b, "{\"ok\":true,\"to\":\"%s\"}", object_getClassName(fr));
    }
    else if (!strcmp(cmd, "menus")) {
        id menu = msg(nsapp(), "mainMenu");
        if (!menu) { buf_error(b, "no main menu"); goto done; }
        buf_puts(b, "{\"ok\":true,\"menu\":");
        emit_menu(b, menu);
        buf_puts(b, "}");
    }
    else if (!strcmp(cmd, "menu")) {
        if (argc < 2) { buf_error(b, "usage: menu <A>B>C>"); goto done; }
        const char *err = menu_perform(argv[1], b);
        if (err) buf_error(b, "%s", err);
    }
    else if (!strcmp(cmd, "screenshot")) {
        if (argc < 3) { buf_error(b, "usage: screenshot <win> <path.png>"); goto done; }
        win = window_arg(argv[1]);
        if (!win) { buf_error(b, "no such window"); goto done; }
        const char *err = window_screenshot(win, argv[2]);
        if (err) buf_error(b, "%s", err);
        else buf_printf(b, "{\"ok\":true,\"path\":\"%s\"}", argv[2]);
    }
    else if (!strcmp(cmd, "lock")) {
        if (argc < 2) { buf_error(b, "usage: lock on|off"); goto done; }
        g_lock_input = !strcmp(argv[1], "on");
        buf_printf(b, "{\"ok\":true,\"locked\":%s}", g_lock_input ? "true" : "false");
    }
    else if (!strcmp(cmd, "suppress") || !strcmp(cmd, "unsuppress")) {
        if (argc < 2) { buf_error(b, "usage: %s <selector>", cmd); goto done; }
        pthread_mutex_lock(&g_lock);
        if (cmd[0] == 's') {
            bool exists = false;
            for (int i = 0; i < g_nsuppress; i++) if (!strcmp(g_suppress[i], argv[1])) exists = true;
            if (!exists && g_nsuppress < MAX_SUPPRESS) g_suppress[g_nsuppress++] = strdup(argv[1]);
        } else {
            for (int i = 0; i < g_nsuppress; i++)
                if (!strcmp(g_suppress[i], argv[1])) {
                    free(g_suppress[i]);
                    g_suppress[i] = g_suppress[--g_nsuppress];
                    break;
                }
        }
        pthread_mutex_unlock(&g_lock);
        buf_puts(b, "{\"ok\":true}");
    }
    else if (!strcmp(cmd, "suppressed")) {
        buf_puts(b, "{\"ok\":true,\"suppressed\":[");
        pthread_mutex_lock(&g_lock);
        for (int i = 0; i < g_nsuppress; i++) { if (i) buf_puts(b, ","); buf_json_str(b, g_suppress[i]); }
        pthread_mutex_unlock(&g_lock);
        buf_puts(b, "]}");
    }
    else if (!strcmp(cmd, "watch"))   { r->want_watch = true;   buf_puts(b, "{\"ok\":true,\"watching\":true}"); }
    else if (!strcmp(cmd, "unwatch")) { r->want_unwatch = true; buf_puts(b, "{\"ok\":true,\"watching\":false}"); }
    else buf_error(b, "unknown command: %s (try 'help')", cmd);

done:
    buf_puts(b, "\n");
    objc_autoreleasePoolPop(pool);
}

/* ------------------------------------------------------------------ */
/* socket server                                                      */
/* ------------------------------------------------------------------ */

/* split a command line into argv in place. tokens are whitespace separated;
 * a token may be "double quoted" to include spaces (so text args can have them). */
static int tokenize(char *line, char **argv, int max) {
    int argc = 0;
    char *p = line;
    while (*p && argc < max) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        char *out;
        if (*p == '"') {
            p++;
            argv[argc++] = out = p;
            char *w = p;
            while (*p && *p != '"') {
                if (*p == '\\' && p[1]) p++;
                *w++ = *p++;
            }
            if (*p == '"') p++;
            *w = 0;
        } else {
            argv[argc++] = p;
            while (*p && *p != ' ' && *p != '\t') p++;
            if (*p) *p++ = 0;
        }
        (void)out;
    }
    return argc;
}

static void *client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    char line[8192];
    size_t have = 0;
    bool watching = false;
    for (;;) {
        ssize_t n = recv(fd, line + have, sizeof(line) - have - 1, 0);
        if (n <= 0) break;
        have += (size_t)n;
        line[have] = 0;
        char *start = line, *nl;
        while ((nl = memchr(start, '\n', line + have - start))) {
            *nl = 0;
            char *cmdline = start;
            start = nl + 1;
            while (*cmdline == ' ' || *cmdline == '\t') cmdline++;
            if (!*cmdline) continue;

            char *argv[16];
            char work[8192];
            strlcpy(work, cmdline, sizeof work);
            int argc = tokenize(work, argv, 16);
            if (argc == 0) continue;

            req_t req = {0};
            req.argc = argc;
            req.argv = argv;
            req.fd = fd;
            if (!main_queue_ok()) {
                buf_error(&req.out, "host main thread is not servicing the dispatch "
                                    "queue (non-AppKit host?); UI commands unavailable");
                buf_puts(&req.out, "\n");
            } else {
                dispatch_sync_f(dispatch_get_main_queue(), &req, handle_on_main);
            }

            if (req.want_watch   && !watching) { watcher_add(fd);    watching = true;  }
            if (req.want_unwatch &&  watching) { watcher_remove(fd); watching = false; }

            if (req.out.p) {
                ssize_t off = 0;
                while (off < (ssize_t)req.out.len) {
                    ssize_t w = send(fd, req.out.p + off, req.out.len - off, 0);
                    if (w <= 0) goto closeconn;
                    off += w;
                }
                free(req.out.p);
            }
        }
        /* slide any partial line to the front */
        size_t rem = line + have - start;
        memmove(line, start, rem);
        have = rem;
    }
closeconn:
    if (watching) watcher_remove(fd);
    close(fd);
    return NULL;
}

static void *server_thread(void *arg) {
    (void)arg;
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return NULL;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, g_sockpath, sizeof addr.sun_path);
    unlink(g_sockpath);
    if (bind(s, (struct sockaddr *)&addr, sizeof addr) < 0) {
        fprintf(stderr, "[appshim] bind %s failed: %s\n", g_sockpath, strerror(errno));
        close(s);
        return NULL;
    }
    chmod(g_sockpath, 0600);              /* only this user may connect */
    if (listen(s, 8) < 0) { close(s); return NULL; }
    fprintf(stderr, "[appshim] listening on %s (pid %d)\n", g_sockpath, getpid());
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }
        pthread_t t;
        if (pthread_create(&t, NULL, client_thread, (void *)(intptr_t)c) == 0)
            pthread_detach(t);
        else
            close(c);
    }
    close(s);
    unlink(g_sockpath);
    return NULL;
}

/* ------------------------------------------------------------------ */
/* entry point                                                        */
/* ------------------------------------------------------------------ */

__attribute__((constructor))
static void appshim_init(void) {
    const char *env = getenv("APPSHIM_SOCK");
    if (env && *env) strlcpy(g_sockpath, env, sizeof g_sockpath);
    else snprintf(g_sockpath, sizeof g_sockpath, "/tmp/appshim-%d.sock", getpid());

    /* Decide headless up front so install_hooks (which runs on the main queue)
     * can apply the offscreen interposition in the same reliable pass. */
    const char *hl = getenv("APPSHIM_HEADLESS");
    g_headless = (hl && *hl && strcmp(hl, "0")) ? 1 : 0;
    const char *pl = getenv("APPSHIM_PLACE");
    double px, py, pw, ph;
    if (!g_headless && pl && sscanf(pl, "%lf,%lf,%lf,%lf", &px, &py, &pw, &ph) == 4) {
        g_place_rect = CGRectMake(px, py, pw, ph);
        g_place = 1;
    }

    /* Install hooks as soon as NSApplication exists. The constructor can run
     * before the class is realized, so also schedule an install on the main
     * queue; whichever happens first wins and the second call is a no-op. */
    if (objc_getClass("NSApplication")) install_hooks();
    dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)install_hooks);

    pthread_t t;
    if (pthread_create(&t, NULL, server_thread, NULL) == 0) pthread_detach(t);
}
