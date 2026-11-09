/*
 * testapp.m -- a tiny AppKit app to exercise the shim.
 *
 * A window with a counter label, two buttons, a text field, and a checkbox,
 * plus a "Demo" menu. Each control logs to stderr so you can confirm the shim
 * is driving real actions (not just forging events that go nowhere).
 */
#import <Cocoa/Cocoa.h>

@interface Ctl : NSObject
@property (strong) NSTextField *counterLabel;
@property (strong) NSTextField *field;
@property (assign) int count;
@end

@implementation Ctl
- (void)bump:(id)sender {
    self.count++;
    self.counterLabel.stringValue = [NSString stringWithFormat:@"Count: %d", self.count];
    fprintf(stderr, "[testapp] bump -> %d (sender=%s)\n", self.count,
            [[sender className] UTF8String]);
}
- (void)reset:(id)sender {
    self.count = 0;
    self.counterLabel.stringValue = @"Count: 0";
    fprintf(stderr, "[testapp] reset\n");
}
- (void)submit:(id)sender {
    fprintf(stderr, "[testapp] submit field = \"%s\"\n", [self.field.stringValue UTF8String]);
}
- (void)toggle:(id)sender {
    fprintf(stderr, "[testapp] checkbox state = %ld\n", (long)[sender state]);
}
- (void)demoAction:(id)sender {
    fprintf(stderr, "[testapp] menu Demo>Ping fired\n");
}
@end

static NSButton *mkButton(NSString *title, NSString *ident, id target, SEL action, NSRect f) {
    NSButton *b = [[NSButton alloc] initWithFrame:f];
    b.title = title;
    b.identifier = ident;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = target;
    b.action = action;
    return b;
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        Ctl *ctl = [Ctl new];

        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 420, 260)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = @"Shim Test";
        [win center];
        NSView *cv = win.contentView;

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 210, 380, 24)];
        label.stringValue = @"Count: 0";
        label.bezeled = NO;
        label.editable = NO;
        label.drawsBackground = NO;
        label.identifier = @"counter";
        label.font = [NSFont systemFontOfSize:18];
        ctl.counterLabel = label;
        [cv addSubview:label];

        [cv addSubview:mkButton(@"Increment", @"inc", ctl, @selector(bump:), NSMakeRect(20, 160, 120, 32))];
        [cv addSubview:mkButton(@"Reset", @"reset", ctl, @selector(reset:), NSMakeRect(150, 160, 120, 32))];

        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 110, 250, 24)];
        field.placeholderString = @"type here";
        field.identifier = @"name";
        ctl.field = field;
        [cv addSubview:field];

        [cv addSubview:mkButton(@"Submit", @"submit", ctl, @selector(submit:), NSMakeRect(280, 108, 120, 28))];

        NSButton *check = [[NSButton alloc] initWithFrame:NSMakeRect(20, 60, 200, 24)];
        [check setButtonType:NSButtonTypeSwitch];
        check.title = @"Enable feature";
        check.identifier = @"feature";
        check.target = ctl;
        check.action = @selector(toggle:);
        [cv addSubview:check];

        /* menu bar: App menu (Quit) + Demo menu (Ping) */
        NSMenu *mainMenu = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        [mainMenu addItem:appItem];
        NSMenu *appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"Quit Shim Test" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;

        NSMenuItem *demoItem = [NSMenuItem new];
        [mainMenu addItem:demoItem];
        NSMenu *demoMenu = [[NSMenu alloc] initWithTitle:@"Demo"];
        NSMenuItem *ping = [demoMenu addItemWithTitle:@"Ping" action:@selector(demoAction:) keyEquivalent:@""];
        ping.target = ctl;
        demoItem.submenu = demoMenu;
        app.mainMenu = mainMenu;

        [win makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        fprintf(stderr, "[testapp] ready, window #%ld\n", (long)win.windowNumber);
        [app run];
    }
    return 0;
}
