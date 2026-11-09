#!/bin/bash
# shim-launch.sh -- copy an app, re-sign the whole bundle with permissive
# entitlements, and launch the copy with appshim.dylib inserted.
#
# This is the "launcher sandbox": it works for apps that do NOT verify their
# own code signature at runtime. It cannot defeat SIP-protected system apps,
# and it does not help with apps whose UI is not native AppKit.
#
# usage: shim-launch.sh /path/to/App.app [args...]
set -euo pipefail
SRC="$1"; shift || true
[ -d "$SRC" ] || { echo "not an .app bundle: $SRC" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$HERE/build/appshim.dylib"
[ -f "$DYLIB" ] || { echo "build the shim first: make all" >&2; exit 2; }

NAME="$(basename "$SRC" .app)"
DST="/tmp/${NAME}-shim.app"
SOCK="/tmp/appshim-${NAME}.sock"
rm -rf "$DST"; cp -R "$SRC" "$DST"

# permissive entitlements: allow the dyld env var and skip library validation
ENTS="$(mktemp /tmp/appshim-ents-XXXXXX)"
cat > "$ENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
PLIST

echo ">> deep re-signing $DST (bottom-up) ..."
# bottom-up: nested Mach-O first, main bundle last, each keeping hardened runtime
find "$DST" \( -name '*.dylib' -o -name '*.so' \) -type f 2>/dev/null | while read -r f; do
  codesign --force --sign - --options runtime --timestamp=none "$f" 2>/dev/null || true
done
# nested frameworks / helper bundles
find "$DST/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) 2>/dev/null \
  | sort -r | while read -r b; do
  codesign --force --deep --sign - --options runtime --entitlements "$ENTS" --timestamp=none "$b" 2>/dev/null || true
done
# the main bundle, last
codesign --force --deep --sign - --options runtime --entitlements "$ENTS" --timestamp=none "$DST"

BIN="$DST/Contents/MacOS/$(defaults read "$DST/Contents/Info" CFBundleExecutable 2>/dev/null || echo "$NAME")"
echo ">> launching with shim; socket = $SOCK"
rm -f "$SOCK"
APPSHIM_SOCK="$SOCK" DYLD_INSERT_LIBRARIES="$DYLIB" "$BIN" "$@" >/tmp/${NAME}-shim.out 2>&1 &
echo "pid=$! sock=$SOCK log=/tmp/${NAME}-shim.out"
