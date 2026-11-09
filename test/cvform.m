/* cvform -- a tiny labeled form to validate the cvfill orchestrator.
 * Fields expose their names as placeholders (AXPlaceholderValue) + a11y labels,
 * exactly like a real application form. Not wired to anything. */
#import <Cocoa/Cocoa.h>

@interface AD : NSObject <NSApplicationDelegate> @end
@implementation AD {
    NSWindow *w;
}
- (NSTextField *)fieldAt:(CGFloat)y placeholder:(NSString *)ph into:(NSView *)v {
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(140, y, 230, 24)];
    tf.placeholderString = ph;
    tf.accessibilityLabel = ph;
    NSTextField *lab = [NSTextField labelWithString:ph];
    lab.frame = NSMakeRect(12, y + 2, 120, 20);
    [v addSubview:lab]; [v addSubview:tf];
    return tf;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 320)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
          backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Application";
    NSView *v = w.contentView;
    CGFloat y = 270;
    for (NSString *ph in @[@"First Name", @"Last Name", @"Email Address",
                           @"Phone Number", @"City", @"LinkedIn"]) {
        [self fieldAt:y placeholder:ph into:v]; y -= 40;
    }
    NSButton *b = [NSButton buttonWithTitle:@"Submit" target:nil action:nil];
    b.frame = NSMakeRect(150, 10, 100, 30);
    [v addSubview:b];
    [w makeKeyAndOrderFront:nil];
    fprintf(stderr, "[cvform] ready\n");
}
@end
int main() { @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    AD *d = [AD new]; app.delegate = d;
    [app run]; return 0; } }
