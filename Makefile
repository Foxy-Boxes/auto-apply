# appshim -- AppKit scripting shim via DYLD_INSERT_LIBRARIES
CC      := xcrun clang
CFLAGS  := -O2 -Wall -Wno-deprecated-declarations
BUILD   := build

DYLIB   := $(BUILD)/appshim.dylib
APPCTL  := $(BUILD)/appctl
AXCTL   := $(BUILD)/axctl
UIDRIVE := $(BUILD)/uidrive
OCRTEXT := $(BUILD)/ocrtext
TESTAPP := $(BUILD)/testapp
CVFORM  := $(BUILD)/cvform

.PHONY: all clean run-test
all: $(DYLIB) $(APPCTL) $(AXCTL) $(UIDRIVE) $(OCRTEXT) $(TESTAPP) $(CVFORM)

$(BUILD):
	mkdir -p $(BUILD)

# The injected library. Linked against the frameworks whose classes it drives.
$(DYLIB): src/appshim.c | $(BUILD)
	$(CC) -dynamiclib $(CFLAGS) \
	  -framework CoreFoundation -framework Foundation \
	  -framework AppKit -framework CoreGraphics \
	  -o $@ $<

$(APPCTL): client/appctl.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

# Out-of-process accessibility client (works when injection is blocked).
$(AXCTL): client/axctl.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -framework Cocoa -framework ApplicationServices \
	  -framework CoreGraphics -o $@ $<

# Unified external driver: Accessibility + CGEvent + capture + virtual display.
$(UIDRIVE): client/uidrive.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -framework Cocoa -framework ApplicationServices \
	  -framework CoreGraphics -framework ImageIO -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -o $@ $<

# OCR tool (Vision framework): verify field contents from screenshots.
$(OCRTEXT): client/ocrtext.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework Vision \
	  -framework CoreGraphics -framework ImageIO -o $@ $<

# Test harness app.
$(TESTAPP): test/testapp.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -framework Cocoa -o $@ $<

$(CVFORM): test/cvform.m | $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -framework Cocoa -o $@ $<

# Launch the test app with the shim preloaded.
run-test: all
	APPSHIM_SOCK=/tmp/appshim-test.sock \
	DYLD_INSERT_LIBRARIES=$(DYLIB) $(TESTAPP)

clean:
	rm -rf $(BUILD)
